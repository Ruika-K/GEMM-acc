#!/usr/bin/env python3
"""Place and route on sky130 with OpenROAD, after syn/asic/run.py.

    python3 syn/asic/run.py pe sys_8 bcast_8
    python3 syn/asic/pnr.py pe sys_8 bcast_8
    python3 syn/asic/pnr.py --list
    python3 syn/asic/pnr.py --parse sys_8     # re-read an existing log

Each job takes the netlist and constraints that syn/asic/run.py left in
syn/build/asic/<job>/ and runs syn/asic/pnr.tcl on them: floorplan, power grid,
placement, clock tree, timing repair, global and detailed routing, parasitic
extraction, and timing at three corners with the extracted wires.

Results are written to syn/asic/pnr_results.csv, logs and layouts (DEF, ODB)
to syn/build/asic/<design>/pnr/. Jobs come in two kinds:

  * pe, sys_N, bcast_N: the full flow. Timing-driven placement, detailed
    routing, timing with extracted parasitics.
  * sys_N_est, bcast_N_est: a reduced flow for blocks too large for the full
    one here. Placement for wire length only, global routing only, timing with
    the wire estimates of global routing. Logs in .../pnr_est/.
  * pe*_macro: the PE as a hard macro (pnr.tcl with PNR_MACRO=1), with pins
    on matching tracks on opposite edges, an abstract (LEF) and timing models
    (Liberty). Output in syn/build/asic/pe*/macro/.
  * sys_N*_hier: the systolic array placed and routed hierarchically
    (pnr_hier.tcl): N x N copies of the macro on a grid, the rest of the array
    placed, routed and extracted around them. Timing at the end is a flat
    analysis (sta_flat.tcl) with the netlists and extracted parasitics of the
    top level and of every PE; "fmax_ss_model_mhz" is what the top level saw
    through the timing models of the macro, combined with the paths inside the
    macro. Output in syn/build/asic/sys_N*/pnr_hier/.

Frequencies are 1000 / (period - slack) of the worst register-to-register
path; hold slack is the worst over all paths and corners.

The clock period is not the one used for synthesis. Synthesis maps for 5 ns,
which the typical corner almost reaches. Place and route optimises all three
corners at once and has to close the slow one, where 5 ns is out of reach by a
factor of two. PERIOD is a target the slow corner misses by 10 - 20 %, so the
numbers are what the tools reach when pushed, not what they were asked for.
The faster variants get shorter periods, PERIOD_S8 and PERIOD_M4, chosen the
same way.

A macro is timed on its own, so its inputs and outputs need budgets: what
part of the clock period the path from one PE to the next may spend on either
side. Each PE output comes straight from a register; each input goes into the
multiplier, which is the long part. MACRO_IN is the share of the period an
input may assume is already used when it arrives (the clock-to-output time of
the neighbour and the wire in between), MACRO_OUT the share an output has to
leave to the neighbour. The two add up to one period.

Two columns are sanity checks on the timing repair step, which was seen to
insert long buffer chains (see pnr.tcl): "crit_path_bufs" counts the buffers on
the worst path, "buf_chain" is the longest chain of single-fanout buffers
anywhere in the routed netlist.

Needs openroad on PATH and the sky130A PDK (PDK_ROOT, default ~/pdk/sky130).
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = ROOT / "syn" / "build" / "asic"
RESULTS = HERE / "pnr_results.csv"
PDK_ROOT = os.environ.get("PDK_ROOT", str(Path.home() / "pdk" / "sky130"))

# Pins on the side their data comes from or goes to, as in the array:
# A enters from the west, B from the north, the shift chain runs south to
# north.
ARRAY_PINS = ("a_i[*] left:* a_valid_i[*] left:* shift_i left:* "
              "b_i[*] top:* c_o[*] top:* c_valid_o[*] top:* c_i[*] bottom:*")
PE_PINS = ("a_i[*] left:* a_valid_i left:* shift_i left:* "
           "a_o[*] right:* a_valid_o right:* shift_o right:* "
           "b_i[*] top:* c_o[*] top:* b_o[*] bottom:* c_i[*] bottom:*")
BCAST_PINS = ARRAY_PINS.replace("a_valid_i[*]", "a_valid_i").replace("c_valid_o[*]", "c_valid_o")

PERIOD = 10.0     # ns, see above
PERIOD_S8 = 7.0   # ns, for the variant with saved carries (_s8)
PERIOD_M4 = 5.0   # ns, for the variant with the carry-save multiplier as well (_m4)
HOLD_MARGIN = 0.1 # ns of hold slack that the repair before routing has to leave
# OpenRAM SRAM macros of the complete chip (see syn/asic/gemm_mem_sky130.sv).
SRAM_REF = Path(PDK_ROOT) / "sky130A" / "libs.ref" / "sky130_sram_macros"
SRAM_MACROS = ("sky130_sram_1kbyte_1rw1r_32x256_8", "sky130_sram_2kbyte_1rw1r_32x512_8")
SRAM_LIBS = [SRAM_REF / "lib" / f"{m}_TT_1p8V_25C.lib" for m in SRAM_MACROS]

MACRO_IN = 0.3    # share of the period used before a macro input, see above
MACRO_OUT = 0.7   # share of the period left after a macro output
MACRO_HOLD = 0.3  # ns an output of a macro stays unchanged after the clock edge
MACRO_CLK_SLEW = 0.5   # ns transition of the clock at a macro pin, see macro_constraints
CHANNEL_X = 13.8  # um between macro columns (30 sites; with 26, clock buffers
                  # found no room between the tap cells)
CHANNEL_Y = 5.44  # um between macro rows (2 rows)
# Chip: the PEs get the clock this much later than the registers around the
# array (ns, slow corner). With the clocks lined up, the paths into the PEs had
# -0.36 ns of slack and the paths out of them +1.94 ns, so 0.3 ns later looked
# like free time. It was not (-0.45 ns, 184 instead of 187 MHz): the worst of
# those paths start at the registers that get the clock last in their own tree,
# 0.3 ns after the median, and a third of the path is the register driving the
# wire into the PE. With the clock gate of the chip (step 12) the registers
# behind the gate are spread wider and the PEs have to be later: one delay
# buffer (0.2 ns) took the chip from 183 to 190 MHz, two (0.35 asks for two)
# to 194 MHz, with hold still met (+0.10 ns) and the paths out of the PEs at
# +1.8 ns; the slowest path is then elsewhere (output FIFO to serialiser).
PE_CLK_LATE = 0.35
# Chip: the SRAM clock pins get the clock this much earlier than the registers
# around the array (ns, slow corner). Clock tree synthesis lines them up with
# the registers, but the read data of an SRAM comes after the falling edge,
# so the paths out of it have half a cycle and the paths into it a whole one.
# With the SRAMs lined up, the paths out had -0.25 / +0.08 / +0.02 ns of slack
# (A / B / bias) and the paths in +0.86 / +0.41 / +0.74 ns.
SRAM_CLK_EARLY = 0.35

FIELDS = ["job", "top", "placement", "routing", "util_target", "die_um2", "cell_um2", "util_pct", "period_ns",
          "fmax_tt_mhz", "fmax_ss_mhz", "fmax_ff_mhz", "crit_path_bufs", "buf_chain", "hold_slack_ns",
          "skew_ns", "macro_skew_ss_ns", "drc", "wire_um", "fmax_ss_model_mhz", "hold_in_ns", "sram_slack_ss_ns",
          "runtime_s"]


def jobs():
    """Job table: the plain datapath, the variant with a carry saved every 8
    bits of the accumulator (suffix _s8) and the one that also has the
    multiplier without a final adder (suffix _m4), see syn/asic/run.py.

    The faster a variant, the shorter its clock period, so that all are pushed
    equally hard.
    """
    out = {}
    for sfx, period in (("", PERIOD), ("_s8", PERIOD_S8), ("_m4", PERIOD_M4)):
        full = dict(util=50, period=period)
        out[f"pe{sfx}"] = dict(top="gemm_pe", pins=PE_PINS, **full)
        for n in (4, 8):
            out[f"sys_{n}{sfx}"] = dict(top="gemm_array", pins=ARRAY_PINS, **full)
            out[f"bcast_{n}{sfx}"] = dict(top="gemm_array_bcast", pins=BCAST_PINS, **full)
        # 16 x 16 is about 160 000 cells. Timing-driven placement and detailed
        # routing would each take hours, so the two arrays go through a
        # reduced flow: placement for wire length, buffering by repair_design,
        # timing from global routing. The 8 x 8 arrays are run through it as
        # well, to show what the reduced flow does to each architecture where
        # the full one is known.
        est = dict(util=50, period=period, droute=False, timing_place=False)
        for n in (8, 16):
            out[f"sys_{n}{sfx}_est"] = dict(top="gemm_array", design=f"sys_{n}{sfx}",
                                            pins=ARRAY_PINS, **est)
            out[f"bcast_{n}{sfx}_est"] = dict(top="gemm_array_bcast", design=f"bcast_{n}{sfx}",
                                              pins=BCAST_PINS, **est)
        # Hierarchical flow: the PE hardened once, the array built from copies.
        out[f"pe{sfx}_macro"] = dict(top="gemm_pe", design=f"pe{sfx}", util=55, period=period,
                                     macro=True)
        for n in (8, 16):
            out[f"sys_{n}{sfx}_hier"] = dict(top="gemm_array", design=f"sys_{n}{sfx}", util=50,
                                             period=period, hier=f"pe{sfx}_macro", rows=n, cols=n,
                                             pins=ARRAY_PINS)
        # The complete chip: PE macros, SRAM macros, the rest in standard cells.
        out[f"chip_8{sfx}"] = dict(top="gemm_top", design=f"chip_8{sfx}", util=50, period=period,
                                   hier=f"pe{sfx}_macro", rows=8, cols=8, chip=True, pins="")
    return out


def section(log, name):
    m = re.search(rf"^SECTION {re.escape(name)}$(.*?)^SECTION ", log, flags=re.M | re.S)
    return m.group(1) if m else ""


def slack(text):
    m = re.search(r"^\s*(-?[0-9.]+)\s+slack", text, flags=re.M)
    return float(m.group(1)) if m else None


def constraints(src, work, period):
    """Copy the synthesis constraints with another clock period.

    Input and output delays keep their share of the period.
    """
    sdc = (src / "constraints.sdc").read_text()
    scale = period / float(re.search(r"-period\s+([0-9.]+)", sdc).group(1))
    sdc = re.sub(r"-period\s+[0-9.]+", f"-period {period}", sdc)
    sdc = re.sub(r"(set_(?:input|output)_delay\s+)([0-9.]+)",
                 lambda m: f"{m.group(1)}{float(m.group(2)) * scale:g}", sdc)
    (work / "constraints.sdc").write_text(sdc)


def macro_constraints(src, work, period):
    """Constraints of a macro: the clock, and the budgets of its inputs and
    outputs (MACRO_IN, MACRO_OUT).

    Hold is a contract between neighbours, MACRO_HOLD: every output stays
    unchanged for at least that long after the clock edge (minimum output
    delay -MACRO_HOLD), and every input may change that early (minimum input
    delay MACRO_HOLD). The macro then repairs hold on its own short input
    paths, such as the one from b_i to the register that forwards it. Left to
    the top level, a hold buffer would have to go on the wire to b_i as a whole
    and slow down the multiplier behind it as well.

    The clock reaches the macro through the clock tree of the top level, with a
    slow edge: 0.35 ns at the slow corner was measured at one of the macros of
    the 8 x 8 array. Characterised with an ideal clock edge instead, the clock
    tree inside the macro looked 0.15 ns faster than it is, and the timing
    model hid a hold violation on a path from an input of the block. With
    0.35 ns some of these paths were still 0.1 ns worse in the flat analysis
    than through the models (the macros see different edges, the model has
    one), so MACRO_CLK_SLEW is set above that. Paths between two macros do not
    depend on it: the clock tree inside the macro delays launch and capture
    alike."""
    sdc = (src / "constraints.sdc").read_text()
    keep = [l for l in sdc.splitlines() if not re.match(r"\s*(create_clock|set_(input|output)_delay)", l)]
    data_in = 'set data_in [get_ports * -filter "direction == input && name != clk"]'
    lines = [f"create_clock -name clk -period {period} [get_ports clk]", data_in,
             f"set_input_delay  -max {MACRO_IN * period:g} -clock clk $data_in",
             f"set_input_delay  -min {MACRO_HOLD:g} -clock clk $data_in",
             f"set_output_delay -max {MACRO_OUT * period:g} -clock clk [all_outputs]",
             f"set_output_delay -min {-MACRO_HOLD:g} -clock clk [all_outputs]",
             f"set_input_transition {MACRO_CLK_SLEW:g} [get_ports clk]"]
    lines += [l for l in keep if l.strip() and not l.startswith("set data_in")]
    (work / "constraints.sdc").write_text("\n".join(lines) + "\n")


def port_bits(netlist, module):
    """Port name -> width of a module in a netlist."""
    body = re.search(rf"^module {re.escape(module)}\(.*?^endmodule", netlist, flags=re.M | re.S).group(0)
    widths = {}
    for m in re.finditer(r"^\s*(?:input|output)\s+(?:\[(\d+):0\]\s+)?(\w+);", body, flags=re.M):
        widths[m.group(2)] = int(m.group(1)) + 1 if m.group(1) else 1
    return widths


def pe_edges(netlist):
    """Pin order per edge of the PE macro. A enters from the west and leaves
    to the east, B from the north to the south, the shift chain from the south
    to the north. Pin k of the west edge is level with pin k of the east edge,
    pin k of the north edge above pin k of the south edge."""
    w = port_bits(netlist, "gemm_pe")

    def bits(name):
        return [name] if w[name] == 1 else [f"{name}[{k}]" for k in range(w[name])]

    edges = {
        "left": ["a_valid_i", "shift_i"] + bits("a_i"),
        "right": ["a_valid_o", "shift_o"] + bits("a_o"),
        "top": bits("b_i") + bits("c_o"),
        "bottom": bits("b_o") + bits("c_i") + ["clk", "rst_n"],
    }
    return " ".join(f"{e} {{{' '.join(pins)}}}" for e, pins in edges.items())


def black_box(netlist, cell):
    """The array netlist with the PE as a black box: the modules below the PE
    are taken out, and its instances refer to the macro by name."""
    pe = re.search(rf"^module (\S+\\{cell}) ", netlist, flags=re.M).group(1)
    below = set(re.findall(r"^\s+(\S+\\gemm_mac\w*)\s", re.search(
        rf"^module {re.escape(pe)} .*?^endmodule", netlist, flags=re.M | re.S).group(0), flags=re.M))
    for name in [pe, *below]:
        netlist = re.sub(rf"^module {re.escape(name)} .*?^endmodule\n", "", netlist, flags=re.M | re.S)
    return netlist.replace(pe + " ", cell + " ")


def path_buffers(text):
    """Number of buffer cells on a reported path."""
    return len(re.findall(r"\(sky130_fd_sc_hd__(?:buf|clkbuf|dlygate|dlymetal)", text))


def longest_buffer_chain(netlist):
    """Longest chain of buffers that each drive exactly one cell input.

    Buffers inserted for hold are left out: a chain of those is a delay line
    put there on purpose.
    """
    drives = {}     # output net of a buffer -> its input net
    loads = {}      # net -> number of cell inputs on it
    for m in re.finditer(r"^\s*(sky130_\w+)\s+(\S+)\s*\((.*?)\);", netlist, flags=re.M | re.S):
        pins = dict(re.findall(r"\.(\w+)\(\s*(.*?)\s*\)", m.group(3), flags=re.S))
        is_buf = (re.search(r"__(buf|clkbuf|dlygate|dlymetal)", m.group(1)) and "X" in pins
                  and not re.search(r"hold\d+$", m.group(2).rstrip()))
        for pin, net in pins.items():
            if pin not in ("X", "Y", "Q", "Q_N", "HI", "LO", "VPWR", "VGND", "VPB", "VNB"):
                loads[net] = loads.get(net, 0) + 1
        if is_buf:
            drives[pins["X"]] = pins["A"]
    best = 0
    for net in drives:
        n = 0
        while net in drives and loads.get(net, 0) <= 1:
            net = drives[net]
            n += 1
        best = max(best, n)
    return best


def dirs(name, job):
    """Directory of the synthesised design and working directory of a job."""
    src = BUILD / job.get("design", name)
    if job.get("macro"):
        return src, src / "macro"
    if job.get("chip"):
        return src, src / "pnr"
    if job.get("hier"):
        return src, src / "pnr_hier"
    return src, src / ("pnr_est" if name.endswith("_est") else "pnr")


def run(name, job, threads=4):
    """Run OpenROAD for one job and return its run time in seconds."""
    src, work = dirs(name, job)
    if not (src / "netlist.v").exists():
        raise FileNotFoundError(f"run syn/asic/run.py {src.name} first")
    work.mkdir(exist_ok=True)
    period = job.get("period", PERIOD)
    netlist = src / "netlist.v"
    script = "pnr.tcl"
    env = dict(os.environ, PDK_ROOT=PDK_ROOT, PNR_TOP=job["top"],
               PNR_SDC=str(work / "constraints.sdc"), PNR_OUT=str(work),
               PNR_UTIL=str(job["util"]), PNR_DENSITY=str(job.get("density", 0.6)),
               PNR_HOLD_MARGIN=str(HOLD_MARGIN))
    if job.get("macro"):
        macro_constraints(src, work, period)
        env.update(PNR_MACRO="1", PNR_EDGES=pe_edges(netlist.read_text()))
    else:
        constraints(src, work, period)
        env.update(PNR_PINS=job["pins"])
    if job.get("hier"):
        mjob = jobs()[job["hier"]]
        mdir = dirs(job["hier"], mjob)[1]
        if not (mdir / f"{mjob['top']}.lef").exists():
            raise FileNotFoundError(f"run syn/asic/pnr.py {job['hier']} first")
        bb = work / "netlist.v"
        bb.write_text(black_box(netlist.read_text(), mjob["top"]))
        netlist = bb
        script = "pnr_hier.tcl"
        # Hold from the block inputs is not repaired here, see sta_flat.tcl.
        sdc = (work / "constraints.sdc").read_text()
        (work / "constraints_top.sdc").write_text(sdc + "set_false_path -hold -from [all_inputs]\n")
        env["PNR_SDC"] = str(work / "constraints_top.sdc")
        env.update(PNR_MACRO_DIR=str(mdir), PNR_MACRO_CELL=mjob["top"],
                   PNR_ROWS=str(job["rows"]), PNR_COLS=str(job["cols"]),
                   PNR_CHANNEL_X=str(CHANNEL_X), PNR_CHANNEL_Y=str(CHANNEL_Y))
        if job.get("chip"):
            script = "pnr_top.tcl"
            env.update(PNR_PE_CLK_LATE=str(PE_CLK_LATE), PNR_SRAM_CLK_EARLY=str(SRAM_CLK_EARLY),
                       PNR_SRAM_LEFS=" ".join(str(SRAM_REF / "lef" / f"{m}.lef") for m in SRAM_MACROS),
                       PNR_SRAM_LIBS=" ".join(str(f) for f in sram_libs(work)))
    else:
        env.update(PNR_DROUTE="1" if job.get("droute", True) else "0",
                   PNR_TIMING_PLACE="1" if job.get("timing_place", True) else "0")
    env["PNR_NETLIST"] = str(netlist)
    t0 = time.time()
    with open(work / "pnr.log", "w") as f:
        subprocess.run(["openroad", "-no_init", "-exit", "-threads", str(threads),
                        str(HERE / script)],
                       stdout=f, stderr=subprocess.STDOUT, env=env, check=True)
    if job.get("macro"):
        timing_models(job, work)
    if job.get("hier"):
        sta_flat(job, work, mdir, mjob["top"])
    return time.time() - t0


def timing_models(job, work):
    """Timing models of a macro, one per corner, see etm.tcl."""
    for corner in ("tt", "ss", "ff"):
        env = dict(os.environ, PDK_ROOT=PDK_ROOT, ETM_TOP=job["top"], ETM_CORNER=corner,
                   ETM_DIR=str(work))
        with open(work / f"etm_{corner}.log", "w") as f:
            subprocess.run(["sta", "-no_init", "-exit", str(HERE / "etm.tcl")],
                           stdout=f, stderr=subprocess.STDOUT, env=env, check=True)


def sram_libs(work):
    """Timing models of the SRAM macros, with one limit taken out.

    The OpenRAM models put a maximum transition of 0.04 ns on every input pin,
    which no driver at the end of a wire meets; with it, electrical repair
    gives up at once. These copies leave the inputs to the library default
    (0.5 ns). Nothing else is changed.
    """
    out = []
    for lib in SRAM_LIBS:
        text = re.sub(r"^\s*max_transition\s*:\s*0\.04\s*;\s*\n", "", lib.read_text(), flags=re.M)
        path = work / lib.name
        path.write_text(text)
        out.append(path)
    return out


def sta_flat(job, work, mdir, cell):
    """Flat timing analysis of a hierarchical job, see sta_flat.tcl."""
    env = dict(os.environ, PDK_ROOT=PDK_ROOT, STA_TOP=job["top"],
               STA_EXTRA_LIBS=" ".join(str(work / f.name) for f in SRAM_LIBS) if job.get("chip") else "",
               STA_SDC=str(work / "constraints.sdc"),
               STA_TOP_V=str(work / f"{job['top']}.pnr.v"),
               STA_TOP_SPEF=str(work / f"{job['top']}.spef"),
               STA_MACRO_V=str(mdir / f"{cell}.pnr.v"),
               STA_MACRO_SPEF=str(mdir / f"{cell}.spef"),
               STA_MACRO_CELL=cell)
    with open(work / "sta_flat.log", "w") as f:
        subprocess.run(["sta", "-no_init", "-exit", str(HERE / "sta_flat.tcl")],
                       stdout=f, stderr=subprocess.STDOUT, env=env, check=True)


def parse(name, job, runtime=None):
    """Turn the log and layout of a finished job into one row of the table."""
    src, work = dirs(name, job)
    log = (work / "pnr.log").read_text()
    if "SECTION end" not in log:
        raise RuntimeError("flow stopped early")
    if runtime is None:
        m = re.search(r"^elapsed (\d+) s", log, flags=re.M)
        runtime = int(m.group(1)) if m else None

    period = float(re.search(r"-period\s+([0-9.]+)", (work / "constraints.sdc").read_text()).group(1))
    model = ""
    timing = log
    if job.get("hier"):
        # Paths between macros as the top level saw them through the timing
        # models, and paths inside the macro from the macro's own run.
        mjob = jobs()[job["hier"]]
        mlog = (dirs(job["hier"], mjob)[1] / "pnr.log").read_text()
        worst = min(slack(section(log, "setup_r2r ss")), slack(section(mlog, "setup_r2r ss")))
        model = f"{1000 / (period - worst):.0f}"
        timing = (work / "sta_flat.log").read_text()
        if "SECTION end" not in timing:
            raise RuntimeError("flat timing analysis stopped early")
        # SPEF nodes that name no pin: the parasitics of those nets were dropped.
        lost = len(re.findall(r"^Warning 1652: .* not found", timing, flags=re.M))
        if lost:
            raise RuntimeError(f"flat timing analysis: {lost} SPEF nodes not found, see sta_flat.log")
    fmax = {c: 1000 / (period - slack(section(timing, f"setup_r2r {c}"))) for c in ("tt", "ss", "ff")}
    bufs = max(path_buffers(section(timing, f"setup_r2r {c}")) for c in ("tt", "ss", "ff"))
    chain = longest_buffer_chain((work / f"{job['top']}.pnr.v").read_text())
    # Hierarchical jobs: hold between registers; the paths from the block
    # inputs are reported separately (hold_in), see sta_flat.tcl.
    hold_sec = "hold_r2r" if job.get("hier") else "hold_all"
    hold = min(slack(section(timing, f"{hold_sec} {c}")) for c in ("tt", "ss", "ff"))
    hold_in = (f"{min(slack(section(timing, f'hold_in {c}')) for c in ('tt', 'ss', 'ff')):.3f}"
               if job.get("hier") else "")
    # Chip: worst setup slack at the slow corner of the paths that start or end
    # at an SRAM macro, with the macro's own times from its (typical) model.
    sram = ""
    if job.get("chip"):
        sram = f"{min(slack(section(timing, f'setup_sram_{d} ss')) for d in ('out', 'in')):.3f}"
    area = re.search(r"Design area\s+([0-9.]+)\s+\S+\s+([0-9.]+)%", section(log, "area"))
    die = re.search(r"DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)",
                    (work / f"{job['top']}.def").read_text())
    die_um2 = (int(die.group(3)) - int(die.group(1))) * (int(die.group(4)) - int(die.group(2))) / 1e6
    skew = re.search(r"^\s*(-?[0-9.]+)\s+setup skew", section(timing, "clock skew"), flags=re.M)
    # Hierarchical jobs: worst clock skew between neighbouring macros of the array.
    mskew = re.search(r"worst difference between neighbours ([0-9.]+) ns", timing) if job.get("hier") else None
    wire = re.findall(r"Total wire length = (\d+) um", log)
    routed = job.get("droute", True)
    placement = "timing" if job.get("timing_place", True) else "wire length"
    if job.get("macro"):
        placement = "timing, macro"
    elif job.get("hier"):
        placement = "timing, hierarchical"
    drc = (work / "drc.rpt").read_text().count("violation type:") if routed else ""
    return dict(
        job=name, top=job["top"],
        placement=placement,
        routing="detailed" if routed else "global",
        util_target=job["util"],
        die_um2=f"{die_um2:.0f}",
        cell_um2=f"{float(area.group(1)):.0f}", util_pct=area.group(2),
        period_ns=period,
        fmax_tt_mhz=f"{fmax['tt']:.0f}", fmax_ss_mhz=f"{fmax['ss']:.0f}",
        fmax_ff_mhz=f"{fmax['ff']:.0f}",
        crit_path_bufs=bufs,
        buf_chain=chain,
        hold_slack_ns=f"{hold:.3f}",
        skew_ns=skew.group(1) if skew else "",
        macro_skew_ss_ns=mskew.group(1) if mskew else "",
        drc=drc,
        wire_um=wire[-1] if wire else "",
        fmax_ss_model_mhz=model,
        hold_in_ns=hold_in,
        sram_slack_ss_ns=sram,
        runtime_s="" if runtime is None else f"{runtime:.0f}",
    )


def save(rows, order):
    """Merge rows into the results table, replacing older rows of the same job."""
    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = list(csv.DictReader(f))
    for row in rows:    # a re-parsed log without a run time keeps the recorded one
        if row["runtime_s"] == "":
            row["runtime_s"] = next((r["runtime_s"] for r in old if r["job"] == row["job"]), "")
    old = [r for r in old if r["job"] not in {x["job"] for x in rows}]
    merged = sorted(old + rows, key=lambda r: order.index(r["job"]) if r["job"] in order else 999)
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(merged)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--parse", action="store_true",
                    help="do not run OpenROAD, only re-read the logs of earlier runs")
    ap.add_argument("--jobs", type=int, default=1, help="parallel jobs")
    ap.add_argument("--threads", type=int, default=0,
                    help="threads per job (default: all cores divided by --jobs)")
    args = ap.parse_args()

    all_jobs = jobs()
    if args.list:
        print("\n".join(all_jobs))
        return
    names = args.names or list(all_jobs)
    for n in names:
        if n not in all_jobs:
            sys.exit(f"unknown job {n}")
    threads = args.threads or max(1, (os.cpu_count() or 4) // args.jobs)
    lock = threading.Lock()

    def one(n):
        try:
            runtime = None if args.parse else run(n, all_jobs[n], threads)
            row = parse(n, all_jobs[n], runtime)
        except Exception as e:  # keep going with the other jobs
            print(f"{n}: FAILED ({e}), see {dirs(n, all_jobs[n])[1]}", flush=True)
            return
        print(f"{n}: die {row['die_um2']} um2, util {row['util_pct']}%, "
              f"tt {row['fmax_tt_mhz']} / ss {row['fmax_ss_mhz']} MHz, "
              f"hold {row['hold_slack_ns']} ns, {row['drc']} DRC, {row['runtime_s']} s",
              flush=True)
        if row["crit_path_bufs"] > 10 or row["buf_chain"] > 10:
            print(f"{n}: WARNING, {row['crit_path_bufs']} buffers on the critical path, "
                  f"longest buffer chain {row['buf_chain']}", flush=True)
        with lock:      # saved after every job, so an interrupted sweep keeps its results
            save([row], list(all_jobs))

    with ThreadPoolExecutor(args.jobs) as pool:
        list(pool.map(one, names))


if __name__ == "__main__":
    main()
