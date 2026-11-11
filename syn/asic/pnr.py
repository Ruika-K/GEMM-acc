#!/usr/bin/env python3
"""Place and route on sky130 with OpenROAD, after syn/asic/run.py.

    python3 syn/asic/run.py pe sys_8 bcast_8
    python3 syn/asic/pnr.py pe sys_8 bcast_8
    python3 syn/asic/pnr.py --list

Each job takes the netlist and constraints that syn/asic/run.py left in
syn/build/asic/<job>/ and runs syn/asic/pnr.tcl on them: floorplan, power grid,
placement, clock tree, timing repair, global and detailed routing, parasitic
extraction, and timing at three corners with the extracted wires.

Results are written to syn/asic/pnr_results.csv, logs and layouts (DEF, ODB)
to syn/build/asic/<job>/pnr/. Frequencies are for the worst
register-to-register path; hold slack is the worst over all paths.

Needs openroad on PATH and the sky130A PDK (PDK_ROOT, default ~/pdk/sky130).
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
RESULTS = HERE / "pnr_results.csv"
PDK_ROOT = os.environ.get("PDK_ROOT", str(Path.home() / "pdk" / "sky130"))

# Pins on the side their data comes from or goes to, as in the array:
# A enters from the west, B from the north, the accumulator chain runs south to
# north.
ARRAY_PINS = ("a_i[*] left:* a_valid_i[*] left:* shift_i left:* "
              "b_i[*] top:* c_o[*] top:* c_valid_o[*] top:* c_i[*] bottom:*")
PE_PINS = ("a_i[*] left:* a_valid_i left:* shift_i left:* "
           "a_o[*] right:* a_valid_o right:* shift_o right:* "
           "b_i[*] top:* c_o[*] top:* b_o[*] bottom:* c_i[*] bottom:*")
BCAST_PINS = ARRAY_PINS.replace("a_valid_i[*]", "a_valid_i").replace("c_valid_o[*]", "c_valid_o")

FIELDS = ["job", "top", "util_target", "die_um2", "cell_um2", "util_pct", "period_ns",
          "fmax_tt_mhz", "fmax_ss_mhz", "fmax_ff_mhz", "hold_slack_ns", "skew_ns",
          "drc", "wire_um", "runtime_s"]


def jobs():
    out = {"pe": dict(top="gemm_pe", util=50, pins=PE_PINS),
           "pe_nopipe": dict(top="gemm_pe", util=50, pins=PE_PINS)}
    for n in (4, 8):
        out[f"sys_{n}"] = dict(top="gemm_array", util=50, pins=ARRAY_PINS)
        out[f"bcast_{n}"] = dict(top="gemm_array_bcast", util=50, pins=BCAST_PINS)
    return out


def section(log, name):
    m = re.search(rf"^SECTION {re.escape(name)}$(.*?)^SECTION ", log, flags=re.M | re.S)
    return m.group(1) if m else ""


def slack(text):
    m = re.search(r"^\s*(-?[0-9.]+)\s+slack", text, flags=re.M)
    return float(m.group(1)) if m else None


def run(name, job):
    src = BUILD / name
    if not (src / "netlist.v").exists():
        raise FileNotFoundError(f"run syn/asic/run.py {name} first")
    work = src / "pnr"
    work.mkdir(exist_ok=True)
    env = dict(os.environ, PDK_ROOT=PDK_ROOT, PNR_TOP=job["top"],
               PNR_NETLIST=str(src / "netlist.v"), PNR_SDC=str(src / "constraints.sdc"),
               PNR_OUT=str(work), PNR_UTIL=str(job["util"]),
               PNR_DENSITY=str(job.get("density", 0.6)), PNR_DROUTE="1", PNR_PINS=job["pins"])
    t0 = time.time()
    with open(work / "pnr.log", "w") as f:
        subprocess.run(["openroad", "-no_init", "-exit", "-threads", "4", str(HERE / "pnr.tcl")],
                       stdout=f, stderr=subprocess.STDOUT, env=env, check=True)
    log = (work / "pnr.log").read_text()
    if "SECTION end" not in log:
        raise RuntimeError("flow stopped early")

    period = float(re.search(r"-period\s+([0-9.]+)", (src / "constraints.sdc").read_text()).group(1))
    fmax = {c: 1000 / (period - slack(section(log, f"setup_r2r {c}"))) for c in ("tt", "ss", "ff")}
    hold = min(slack(section(log, f"hold_all {c}")) for c in ("tt", "ss", "ff"))
    area = re.search(r"Design area\s+([0-9.]+)\s+\S+\s+([0-9.]+)%", section(log, "area"))
    die = re.search(r"DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)",
                    (work / f"{job['top']}.def").read_text())
    die_um2 = (int(die.group(3)) - int(die.group(1))) * (int(die.group(4)) - int(die.group(2))) / 1e6
    skew = re.search(r"^\s*(-?[0-9.]+)\s+setup skew", section(log, "clock skew"), flags=re.M)
    wire = re.findall(r"Total wire length = (\d+) um", log)
    drc = (work / "drc.rpt").read_text().count("violation type:")
    return dict(
        job=name, top=job["top"], util_target=job["util"],
        die_um2=f"{die_um2:.0f}",
        cell_um2=f"{float(area.group(1)):.0f}", util_pct=area.group(2),
        period_ns=period,
        fmax_tt_mhz=f"{fmax['tt']:.0f}", fmax_ss_mhz=f"{fmax['ss']:.0f}",
        fmax_ff_mhz=f"{fmax['ff']:.0f}",
        hold_slack_ns=f"{hold:.3f}",
        skew_ns=skew.group(1) if skew else "",
        drc=drc,
        wire_um=wire[-1] if wire else "",
        runtime_s=f"{time.time() - t0:.0f}",
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--jobs", type=int, default=1, help="parallel jobs (each uses 4 threads)")
    args = ap.parse_args()

    all_jobs = jobs()
    if args.list:
        print("\n".join(all_jobs))
        return
    names = args.names or list(all_jobs)
    for n in names:
        if n not in all_jobs:
            sys.exit(f"unknown job {n}")

    def one(n):
        try:
            row = run(n, all_jobs[n])
            print(f"{n}: die {row['die_um2']} um2, util {row['util_pct']}%, "
                  f"tt {row['fmax_tt_mhz']} / ss {row['fmax_ss_mhz']} MHz, "
                  f"hold {row['hold_slack_ns']} ns, {row['drc']} DRC, {row['runtime_s']} s",
                  flush=True)
            return row
        except Exception as e:  # keep going with the other jobs
            print(f"{n}: FAILED ({e}), see {BUILD / n / 'pnr'}", flush=True)
            return None

    with ThreadPoolExecutor(args.jobs) as pool:
        rows = [r for r in pool.map(one, names) if r]

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
