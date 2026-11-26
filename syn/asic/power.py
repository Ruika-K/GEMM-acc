#!/usr/bin/env python3
"""Power of the routed chip from simulated switching activity.

    python3 syn/asic/power.py chip_8_m4              # all workloads
    python3 syn/asic/power.py chip_8_m4 idle         # selected workloads
    python3 syn/asic/power.py chip_8_m4 --parse      # only re-read the reports
    python3 syn/asic/power.py chip_8_m4 --keep-vcd   # do not delete the VCD files

For every workload of tb/test_gemm_power.py: a gate-level simulation of the
routed netlist (syn/asic/gls.py, registers starting at 0) writes the switching
activity of its window to a VCD file, and OpenSTA (power.tcl) turns it into
power at the typical corner, with the extracted parasitics of the top level
and of every PE. The simulation clock is 10 ns (see tb/test_gemm_power.py), so
the power is that at 100 MHz; dynamic power, nearly all of it, scales with
the frequency, and the energy per multiply-accumulate (pJ/MAC) and TOPS/W do
not depend on it.

The SRAM models charge the energy of an access on every clock edge, whether
the macro is selected or not. The SRAM power is therefore given twice: as
the models say (upper bound) and counted only in the cycles in which a port
is selected (lower bound, from the duty of its chip select).

Results: syn/asic/power_results.csv; reports in
syn/build/asic/<job>/pnr/power/<workload>.log.
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gls  # noqa: E402
import pnr  # noqa: E402

RESULTS = HERE / "power_results.csv"
WORKLOADS = ["compute", "idle"]
FIELDS = ["job", "workload", "clk_mhz", "window_ns", "macs", "run_cycles",
          "total_mw", "total_low_mw", "pe_array_mw", "sram_model_mw", "sram_low_mw",
          "clock_tree_mw", "other_mw", "sequential_mw", "combinational_mw", "clock_mw",
          "default_activity_mw", "pj_per_mac", "pj_per_mac_low", "tops_per_w", "tops_per_w_low"]


def analyse(job_name, workload, keep_vcd):
    job = pnr.jobs()[job_name]
    mjob = pnr.jobs()[job["hier"]]
    src, work = pnr.dirs(job_name, job)
    mdir = pnr.dirs(job["hier"], mjob)[1]
    out = work / "power"
    out.mkdir(exist_ok=True)
    vcd = out / f"{workload}.vcd"
    gls.chip(job_name, 0, "test_gemm_power", testcase=[workload], plusargs=[f"+vcd={vcd}"])
    info = json.loads((out / f"{workload}.vcd.json").read_text())
    (out / f"{workload}.json").write_text(json.dumps(info))
    env = dict(os.environ, PDK_ROOT=pnr.PDK_ROOT, STA_TOP=job["top"],
               STA_EXTRA_LIBS=" ".join(str(work / f.name) for f in pnr.SRAM_LIBS),
               STA_SDC=str(work / "constraints.sdc"),
               STA_TOP_V=str(work / f"{job['top']}.pnr.v"),
               STA_TOP_SPEF=str(work / f"{job['top']}.spef"),
               STA_MACRO_V=str(mdir / f"{mjob['top']}.pnr.v"),
               STA_MACRO_SPEF=str(mdir / f"{mjob['top']}.spef"),
               STA_MACRO_CELL=mjob["top"],
               POWER_VCD=str(vcd), POWER_SCOPE="gemm_top_gls/u_netlist",
               POWER_PERIOD=str(info["clk_ns"]))
    with open(out / f"{workload}.log", "w") as f:
        subprocess.run(["sta", "-no_init", "-exit", str(HERE / "power.tcl")],
                       stdout=f, stderr=subprocess.STDOUT, env=env, check=True)
    if not keep_vcd:
        vcd.unlink()


def section(log, name):
    return re.search(rf"^SECTION {name}$(.*?)^SECTION ", log, flags=re.M | re.S).group(1)


def groups(text):
    """Total power (W) of each group of a report_power table."""
    return {m.group(1): float(m.group(2))
            for m in re.finditer(r"^(\w+)\s+\S+\s+\S+\s+\S+\s+(\S+)\s+[\d.]+%", text, flags=re.M)}


def parse(job_name, workload):
    job = pnr.jobs()[job_name]
    work = pnr.dirs(job_name, job)[1] / "power"
    log = (work / f"{workload}.log").read_text()
    if "SECTION end" not in log:
        raise RuntimeError(f"{workload}: power analysis stopped early")
    info = json.loads((work / f"{workload}.json").read_text())
    vcd = section(log, "vcd")
    if not re.search(r"unannotated\s+0\b", vcd):
        raise RuntimeError(f"{workload}: pins without activity from the VCD file")
    g = groups(vcd)
    default = groups(section(log, "default_activity"))["Total"]
    pe = sram = clk = 0.0
    inst_power = {}
    for m in re.finditer(r"^\s*[-\d.e+]+\s+[-\d.e+]+\s+[-\d.e+]+\s+([-\d.e+]+)\s+(\S+)$", section(log, "instances"), flags=re.M):
        power, name = float(m.group(1)), m.group(2).replace("\\", "")
        inst_power[name] = power
        if name.endswith("u_pe"):
            pe += power
        elif "u_sram" in name:
            sram += power
        else:
            clk += power
    sram_low = 0.0
    for m in re.finditer(r"^SRAM (\S+) (\S+) (\S+)$", section(log, "sram_duty"), flags=re.M):
        name, d0, d1 = m.group(1).replace("\\", ""), float(m.group(2)), float(m.group(3))
        sram_low += inst_power[name] * ((1 - d0) + (1 - d1)) / 2
    total = g["Total"]
    total_low = total - sram + sram_low
    t_s = info["window_ns"] * 1e-9
    macs = info["macs"]
    row = dict(job=job_name, workload=workload, clk_mhz=f"{1000 / info['clk_ns']:.0f}",
               window_ns=f"{info['window_ns']:.0f}", macs=macs, run_cycles=info["run_cycles"],
               total_mw=f"{total * 1e3:.1f}", total_low_mw=f"{total_low * 1e3:.1f}",
               pe_array_mw=f"{pe * 1e3:.1f}", sram_model_mw=f"{sram * 1e3:.1f}",
               sram_low_mw=f"{sram_low * 1e3:.1f}", clock_tree_mw=f"{clk * 1e3:.1f}",
               other_mw=f"{(total - pe - sram - clk) * 1e3:.1f}",
               sequential_mw=f"{g['Sequential'] * 1e3:.1f}",
               combinational_mw=f"{g['Combinational'] * 1e3:.1f}",
               clock_mw=f"{g['Clock'] * 1e3:.1f}",
               default_activity_mw=f"{default * 1e3:.1f}")
    for sfx, p in (("", total), ("_low", total_low)):
        row[f"pj_per_mac{sfx}"] = f"{p * t_s / macs * 1e12:.1f}" if macs else ""
        row[f"tops_per_w{sfx}"] = f"{2 * macs / t_s / p / 1e12:.3f}" if macs else ""
    return row


def save(rows):
    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = list(csv.DictReader(f))
    keys = {(r["job"], r["workload"]) for r in rows}
    merged = [r for r in old if (r["job"], r["workload"]) not in keys] + rows
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(merged)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("job")
    ap.add_argument("workloads", nargs="*", default=WORKLOADS)
    ap.add_argument("--parse", action="store_true", help="only read the existing reports")
    ap.add_argument("--keep-vcd", action="store_true")
    args = ap.parse_args()
    rows = []
    for w in args.workloads:
        if not args.parse:
            analyse(args.job, w, args.keep_vcd)
        row = parse(args.job, w)
        print(", ".join(f"{k}={v}" for k, v in row.items() if k not in ("job",)))
        rows.append(row)
    save(rows)


if __name__ == "__main__":
    main()
