#!/usr/bin/env python3
"""ASIC logic synthesis and pre-layout timing on SkyWater sky130 (open source).

    python3 syn/asic/run.py                 # all jobs
    python3 syn/asic/run.py pe sys_8        # selected jobs
    python3 syn/asic/run.py --list

Flow per job:
  1. Yosys elaborates the SystemVerilog, maps it to sky130_fd_sc_hd standard
     cells (ABC, timing driven for the job's clock period) and writes a netlist.
     The module hierarchy is kept: every module is mapped once, so all PEs of
     an array are the same netlist. (Mapping a flattened array gives each PE a
     slightly different implementation and makes the timing depend on the
     array size for no physical reason.)
     The multiply-accumulate datapath, gemm_mac, goes one step further: it is
     synthesised once on its own (jobs mac, mac_nopipe, mac_ripple) and that
     netlist is put into every design that contains it. Technology mapping
     is not reproducible across designs: the same module mapped as part of
     two different arrays differed by about 5 % in speed, which is as much as
     the architectures being compared.
  2. OpenSTA reads the netlist with an SDC file and reports setup slack at the
     typical and the slow corner, and power at the typical corner.

fmax is 1000 / (period - slack) of the worst register-to-register path, i.e.
the speed of the block itself. Paths through the ports are constrained with
20 % of the period outside the block and reported separately (io_slack).

What the numbers are: cell area and timing *before* placement. There are no
wires, no clock tree and no hold fixing yet, so area will grow and frequency
will drop after place and route. Power uses OpenSTA's default switching
activity, not simulation activity. The operand memories are black boxes (they
are SRAM macros in an ASIC) and are not in the area.

Needs yosys (0.40 or newer) and sta (OpenSTA, also shipped with OpenROAD) on
PATH, and the sky130A PDK. Set PDK_ROOT if it is not in ~/pdk/sky130.
Results are written to syn/asic/results.csv.
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = ROOT / "syn" / "build" / "asic"
RESULTS = HERE / "results.csv"

PDK = Path(os.environ.get("PDK_ROOT", Path.home() / "pdk" / "sky130")) / "sky130A"
LIBDIR = PDK / "libs.ref" / "sky130_fd_sc_hd" / "lib"
CORNERS = {
    "tt": LIBDIR / "sky130_fd_sc_hd__tt_025C_1v80.lib",   # typical, 25 C, 1.80 V
    "ss": LIBDIR / "sky130_fd_sc_hd__ss_100C_1v60.lib",   # slow, 100 C, 1.60 V
}
CELL_LISTS = PDK / "libs.tech" / "openlane" / "sky130_fd_sc_hd"
NAND2_AREA = 3.7536          # sky130_fd_sc_hd__nand2_1, um^2: one gate equivalent
DRIVING_CELL = "sky130_fd_sc_hd__inv_2"
LOAD_PF = 0.0334             # input pin of an inv_16
IO_DELAY = 0.2               # fraction of the period reserved outside the block
ADDER = "sklansky"           # carry architecture: ripple, kogge-stone, han-carlson, sklansky

RTL = [ROOT / "rtl" / f for f in (
    "gemm_mac.sv", "gemm_pe.sv", "gemm_array.sv", "gemm_delay.sv", "gemm_fifo.sv", "gemm_ctrl.sv",
    "gemm_core.sv", "gemm_tile_iter.sv", "gemm_load.sv", "gemm_seq.sv", "gemm_out.sv",
    "gemm_csr.sv", "gemm_top.sv")]
BCAST = [ROOT / "rtl" / "gemm_mac.sv", ROOT / "syn" / "common" / "gemm_array_bcast.sv"]
MEM_BB = HERE / "gemm_mem_blackbox.sv"

FIELDS = ["job", "top", "params", "period_ns", "area_um2", "kge", "cells", "flops",
          "seq_area_pct", "r2r_tt_ns", "fmax_tt_mhz", "r2r_ss_ns", "fmax_ss_mhz",
          "io_slack_tt_ns", "power_tt_mw", "synth_s"]


def jobs():
    """Job table. "mac" names the job whose gemm_mac netlist a design uses."""
    mac_src = RTL[:1]
    out = {
        "mac": dict(top="gemm_mac", sources=mac_src, params={"PE_PIPE": 1}),
        "mac_nopipe": dict(top="gemm_mac", sources=mac_src, params={"PE_PIPE": 0}),
        # Ripple-carry accumulator adder, to show what the adder architecture is worth.
        "mac_ripple": dict(top="gemm_mac", sources=mac_src, params={"PE_PIPE": 1}, adder="ripple"),
        "pe": dict(top="gemm_pe", sources=RTL[:2], params={"PE_PIPE": 1}),
        "pe_nopipe": dict(top="gemm_pe", sources=RTL[:2], params={"PE_PIPE": 0}, mac="mac_nopipe"),
    }
    for n in (4, 8, 16):
        out[f"sys_{n}"] = dict(top="gemm_array", sources=RTL[:3], params={"ROWS": n, "COLS": n})
        out[f"bcast_{n}"] = dict(top="gemm_array_bcast", sources=BCAST,
                                 params={"ROWS": n, "COLS": n})
    out["sys_8_ripple"] = dict(top="gemm_array", sources=RTL[:3],
                               params={"ROWS": 8, "COLS": 8}, mac="mac_ripple")
    out["sys_8_nopipe"] = dict(top="gemm_array", sources=RTL[:3],
                               params={"ROWS": 8, "COLS": 8, "PE_PIPE": 0}, mac="mac_nopipe")
    out["core_8"] = dict(top="gemm_core", sources=RTL[:7], params={"ROWS": 8, "COLS": 8})
    out["top_8"] = dict(top="gemm_top", sources=RTL + [MEM_BB],
                        params={"ROWS": 8, "COLS": 8}, clock="aclk")
    for name, job in out.items():
        job.setdefault("period", 5.0)
        if job["top"] != "gemm_mac":
            job.setdefault("mac", "mac")
    return out


def dont_use():
    """Cells the PDK excludes from synthesis (clock cells, low-power cells, ...)."""
    cells = []
    for name in ("no_synth.cells", "drc_exclude.cells"):
        cells += (CELL_LISTS / name).read_text().split()
    return " ".join(f"-dont_use {c}" for c in sorted(set(cells)))


def sh(cmd, log):
    with open(log, "w") as f:
        subprocess.run([str(c) for c in cmd], stdout=f, stderr=subprocess.STDOUT, check=True)


def use_hard_mac(netlist, hard):
    """Replace the gemm_mac module of a netlist by the separately synthesised one."""
    block = r"^module (\S*gemm_mac)\s*\(.*?^endmodule\n"
    body = re.search(block, hard, flags=re.M | re.S).group(0)
    m = re.search(block, netlist, flags=re.M | re.S)
    body = body.replace("module gemm_mac", f"module {m.group(1)} ", 1)
    return netlist[:m.start()] + body + netlist[m.end():]


def synth(name, job, work):
    lib = CORNERS["tt"]
    period_ps = int(job["period"] * 1000)
    # Parameters are set with chparam before elaboration: "hierarchy -chparam"
    # trips an internal assertion in Yosys 0.70 for gemm_array.
    chparam = " ".join(f"-set {k} {v}" for k, v in job["params"].items())
    adder = job.get("adder", os.environ.get("GEMM_ADDER", ADDER))
    extra = f"-extra-map +/choices/{adder}.v" if adder != "ripple" else ""
    (work / "abc.constr").write_text(
        f"set_driving_cell {DRIVING_CELL}\nset_load {LOAD_PF * 1000}\n")
    script = f"""
        read_verilog -sv -DSYNTHESIS {' '.join(str(s) for s in job['sources'])}
        chparam {chparam} {job['top']}
        hierarchy -top {job['top']}
        rename -top {job['top']}
        synth -booth {extra}
        opt -purge
        dfflibmap -liberty {lib} {dont_use()}
        abc -liberty {lib} {dont_use()} -constr {work / 'abc.constr'} -D {period_ps}
        hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
        opt_clean -purge
        write_verilog -noattr -noexpr -nohex -nodec {work / 'netlist_yosys.v'}
    """
    (work / "synth.ys").write_text(script)
    sh(["yosys", "-q", "-l", work / "synth.log", "-s", work / "synth.ys"], work / "synth.out")
    # OpenSTA does not accept "signed" in port and wire declarations.
    text = (work / "netlist_yosys.v").read_text()
    text = re.sub(r"^(\s*(?:input|output|inout|wire)) signed ", r"\1 ", text, flags=re.M)
    # ... nor parameters on black-box instances. Each parameter set becomes a
    # macro of its own, e.g. gemm_mem_8x8_d1024.
    def macro(m):
        p = {k: int(v, 2) for k, v in re.findall(r"\.(\w+)\(32'sb([01]+)\)", m.group(1))}
        return f"gemm_mem_{p['LANES']}x{p['LANE_W']}_d{p['DEPTH']} "
    text = re.sub(r"gemm_mem #\((.*?)\)\s+(?=\w+ \()", macro, text, flags=re.S)
    if "mac" in job:
        text = use_hard_mac(text, (BUILD / job["mac"] / "netlist.v").read_text())
    (work / "netlist.v").write_text(text)

    # Area and cell counts are taken from the final netlist.
    (work / "stat.ys").write_text(f"""
        read_liberty -lib {lib}
        read_verilog {work / 'netlist.v'}
        hierarchy -top {job['top']}
        tee -o {work / 'stat.txt'} stat -liberty {lib} -top {job['top']}
    """)
    sh(["yosys", "-q", "-s", work / "stat.ys"], work / "stat.out")

    full = (work / "stat.txt").read_text()
    write_breakdown(full, job["top"], work / "breakdown.txt")
    # Totals are in the last section ("design hierarchy" when there are
    # submodules, the module itself otherwise).
    stat = full.split("=== design hierarchy ===")[-1]
    area = float(re.findall(r"Chip area for (?:top )?module.*?:\s*([0-9.]+)", stat)[-1])
    seq = re.findall(r"used for sequential elements:\s*([0-9.]+)\s*\(([0-9.]+)%\)", stat)
    cells = int(re.search(r"^\s*(\d+)\s+\S+\s+cells$", stat, flags=re.M).group(1))
    flops = sum(int(n) for n, c in re.findall(
        r"^\s*(\d+)\s+[0-9.eE+]+\s+(sky130_fd_sc_hd__\w+)$", stat, flags=re.M)
        if "__df" in c or "__sdf" in c or "__edf" in c)
    return area, (float(seq[-1][1]) if seq else 0.0), cells, flops


def short(module):
    """'$paramod$<hash>\\gemm_pe' -> 'gemm_pe'."""
    return module.split("\\")[-1]


def write_breakdown(stat, top, path):
    """Area per module type, without overlap: the cells a module contains
    itself (not those of its submodules), times its number of instances."""
    sections = re.split(r"^=== (.+?) ===$", stat, flags=re.M)
    body = {sections[i]: sections[i + 1] for i in range(1, len(sections) - 1, 2)}
    body.pop("design hierarchy", None)
    line = r"^\s*(\d+)\s+(\S+)\s+(\S+)$"
    local, children = {}, {}
    for name, text in body.items():
        # The count line "<n> <area> submodules", not the word in the table header.
        parts = re.split(r"^\s*\d+\s+\S+\s+submodules$", text, maxsplit=1, flags=re.M)
        head, tail = parts[0], (parts[1] if len(parts) > 1 else "")
        m = re.search(r"^\s*\d+\s+(\S+)\s+cells$", head, flags=re.M)
        local[name] = float(m.group(1)) if m and m.group(1) != "-" else 0.0
        children[name] = [(sub, int(n)) for n, _, sub in re.findall(line, tail, flags=re.M)
                          if sub in body]
    count = {}

    def walk(name, mult):
        count[name] = count.get(name, 0) + mult
        for sub, n in children.get(name, []):
            walk(sub, mult * n)

    walk(top, 1)
    # Several parameterisations of one module (e.g. gemm_delay) are summed.
    rows = {}
    for name, n in count.items():
        r = rows.setdefault(short(name), [0, 0.0])
        r[0] += n
        r[1] += n * local[name]
    total = sum(a for _, a in rows.values())
    lines = [f"{'module':<18}{'instances':>10}{'area um2':>12}{'share':>8}"]
    for name, (n, a) in sorted(rows.items(), key=lambda kv: -kv[1][1]):
        lines.append(f"{name:<18}{n:>10}{a:>12.0f}{100 * a / total:>7.1f}%")
    lines.append(f"{'total':<18}{'':>10}{total:>12.0f}{100.0:>7.1f}%")
    path.write_text("\n".join(lines) + "\n")


def sta(name, job, work, corner):
    clock = job.get("clock", "clk")
    period = job["period"]
    io = IO_DELAY * period
    (work / "constraints.sdc").write_text(f"""
create_clock -name clk -period {period} [get_ports {clock}]
set data_in [get_ports * -filter "direction == input && name != {clock}"]
set_input_delay  {io} -clock clk $data_in
set_output_delay {io} -clock clk [all_outputs]
set_driving_cell -lib_cell {DRIVING_CELL} -pin Y $data_in
set_load {LOAD_PF} [all_outputs]
""")
    (work / f"sta_{corner}.tcl").write_text(f"""
read_liberty {CORNERS[corner]}
read_verilog {work / 'netlist.v'}
link_design {job['top']}
read_sdc {work / 'constraints.sdc'}
puts "SECTION all paths"
report_checks -path_delay max -digits 3
puts "RESULT wns [sta::worst_slack -max]"
puts "SECTION register to register"
report_checks -path_delay max -digits 3 -from [all_registers -clock_pins] -to [all_registers -data_pins]
puts "SECTION power"
report_power
""")
    sh(["sta", "-no_init", "-exit", work / f"sta_{corner}.tcl"], work / f"sta_{corner}.log")
    log = (work / f"sta_{corner}.log").read_text()
    wns = float(re.search(r"RESULT wns (\S+)", log).group(1))
    r2r_section = log.split("SECTION register to register")[1].split("SECTION power")[0]
    r2r = re.search(r"^\s*(-?[0-9.]+)\s+slack", r2r_section, flags=re.M)
    power = re.search(r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)", log, flags=re.M)
    # A block without register-to-register paths is limited by its port paths.
    return (wns, float(r2r.group(1)) if r2r else wns,
            float(power.group(1)) * 1e3 if power else 0.0)


def run(name, job):
    work = BUILD / name
    work.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    area, seq_pct, cells, flops = synth(name, job, work)
    t1 = time.time()
    wns_tt, r2r_tt, power = sta(name, job, work, "tt")
    _, r2r_ss, _ = sta(name, job, work, "ss")
    period = job["period"]
    return dict(
        job=name,
        top=job["top"],
        params=" ".join(f"{k}={v}" for k, v in job["params"].items()),
        period_ns=period,
        area_um2=f"{area:.0f}",
        kge=f"{area / NAND2_AREA / 1000:.1f}",
        cells=cells,
        flops=flops,
        seq_area_pct=f"{seq_pct:.0f}",
        r2r_tt_ns=f"{r2r_tt:.3f}",
        fmax_tt_mhz=f"{1000 / (period - r2r_tt):.0f}",
        r2r_ss_ns=f"{r2r_ss:.3f}",
        fmax_ss_mhz=f"{1000 / (period - r2r_ss):.0f}",
        io_slack_tt_ns=f"{wns_tt:.3f}",
        power_tt_mw=f"{power:.2f}",
        synth_s=f"{t1 - t0:.0f}",
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--jobs", type=int, default=2, help="parallel jobs")
    args = ap.parse_args()

    all_jobs = jobs()
    if args.list:
        print("\n".join(all_jobs))
        return
    if not CORNERS["tt"].exists():
        sys.exit(f"sky130 PDK not found at {PDK} (set PDK_ROOT)")
    names = args.names or list(all_jobs)
    for n in names:
        if n not in all_jobs:
            sys.exit(f"unknown job {n}")

    def one(n):
        try:
            row = run(n, all_jobs[n])
            print(f"{n}: {row['area_um2']} um2 ({row['kge']} kGE), {row['flops']} flops, "
                  f"tt {row['fmax_tt_mhz']} MHz, ss {row['fmax_ss_mhz']} MHz", flush=True)
            return row
        except subprocess.CalledProcessError as e:
            print(f"{n}: FAILED ({Path(str(e.cmd[0])).name}), see {BUILD / n}", flush=True)
            return None

    # The datapath netlists first: the other jobs read them.
    needed = {all_jobs[n]["mac"] for n in names if "mac" in all_jobs[n]}
    first = [n for n in all_jobs if n in needed or (n in names and "mac" not in all_jobs[n])]
    rows = [r for r in map(one, first) if r]
    if len(rows) != len(first):
        sys.exit("datapath synthesis failed")
    with ThreadPoolExecutor(args.jobs) as pool:
        rows += [r for r in pool.map(one, [n for n in names if n not in first]) if r]

    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = [r for r in csv.DictReader(f) if r["job"] not in {x["job"] for x in rows}]
    order = list(all_jobs)
    merged = sorted(old + rows, key=lambda r: order.index(r["job"]) if r["job"] in order else 999)
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(merged)


if __name__ == "__main__":
    main()
