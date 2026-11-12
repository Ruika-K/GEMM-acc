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

Frequencies are 1000 / (period - slack) of the worst register-to-register
path; hold slack is the worst over all paths and corners.

The clock period is not the one used for synthesis. Synthesis maps for 5 ns,
which the typical corner almost reaches. Place and route optimises all three
corners at once and has to close the slow one, where 5 ns is out of reach by a
factor of two. PERIOD is a target the slow corner misses by 10 - 20 %, so the
numbers are what the tools reach when pushed, not what they were asked for.
The variant with saved carries is faster and gets a shorter period, PERIOD_S8,
chosen the same way.

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
PERIOD_S8 = 8.0   # ns, for the variant with saved carries (_s8)

FIELDS = ["job", "top", "placement", "routing", "util_target", "die_um2", "cell_um2", "util_pct", "period_ns",
          "fmax_tt_mhz", "fmax_ss_mhz", "fmax_ff_mhz", "crit_path_bufs", "buf_chain", "hold_slack_ns",
          "skew_ns", "drc", "wire_um", "runtime_s"]


def jobs():
    """Job table: the plain accumulator and the variant with a carry saved
    every 8 bits (suffix _s8, see syn/asic/run.py).

    The faster variant gets a shorter clock period, so that both are pushed
    equally hard.
    """
    out = {}
    for sfx, period in (("", PERIOD), ("_s8", PERIOD_S8)):
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


def path_buffers(text):
    """Number of buffer cells on a reported path."""
    return len(re.findall(r"\(sky130_fd_sc_hd__(?:buf|clkbuf|dlygate|dlymetal)", text))


def longest_buffer_chain(netlist):
    """Longest chain of buffers that each drive exactly one cell input."""
    drives = {}     # output net of a buffer -> its input net
    loads = {}      # net -> number of cell inputs on it
    for m in re.finditer(r"^\s*(sky130_\w+)\s+\S+\s*\((.*?)\);", netlist, flags=re.M | re.S):
        pins = dict(re.findall(r"\.(\w+)\(\s*(.*?)\s*\)", m.group(2), flags=re.S))
        is_buf = re.search(r"__(buf|clkbuf|dlygate|dlymetal)", m.group(1)) and "X" in pins
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
    return src, src / ("pnr_est" if name.endswith("_est") else "pnr")


def run(name, job, threads=4):
    """Run OpenROAD for one job and return its run time in seconds."""
    src, work = dirs(name, job)
    if not (src / "netlist.v").exists():
        raise FileNotFoundError(f"run syn/asic/run.py {src.name} first")
    work.mkdir(exist_ok=True)
    constraints(src, work, job.get("period", PERIOD))
    env = dict(os.environ, PDK_ROOT=PDK_ROOT, PNR_TOP=job["top"],
               PNR_NETLIST=str(src / "netlist.v"), PNR_SDC=str(work / "constraints.sdc"),
               PNR_OUT=str(work), PNR_UTIL=str(job["util"]),
               PNR_DENSITY=str(job.get("density", 0.6)),
               PNR_DROUTE="1" if job.get("droute", True) else "0",
               PNR_TIMING_PLACE="1" if job.get("timing_place", True) else "0",
               PNR_PINS=job["pins"])
    t0 = time.time()
    with open(work / "pnr.log", "w") as f:
        subprocess.run(["openroad", "-no_init", "-exit", "-threads", str(threads),
                        str(HERE / "pnr.tcl")],
                       stdout=f, stderr=subprocess.STDOUT, env=env, check=True)
    return time.time() - t0


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
    fmax = {c: 1000 / (period - slack(section(log, f"setup_r2r {c}"))) for c in ("tt", "ss", "ff")}
    bufs = max(path_buffers(section(log, f"setup_r2r {c}")) for c in ("tt", "ss", "ff"))
    chain = longest_buffer_chain((work / f"{job['top']}.pnr.v").read_text())
    hold = min(slack(section(log, f"hold_all {c}")) for c in ("tt", "ss", "ff"))
    area = re.search(r"Design area\s+([0-9.]+)\s+\S+\s+([0-9.]+)%", section(log, "area"))
    die = re.search(r"DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)",
                    (work / f"{job['top']}.def").read_text())
    die_um2 = (int(die.group(3)) - int(die.group(1))) * (int(die.group(4)) - int(die.group(2))) / 1e6
    skew = re.search(r"^\s*(-?[0-9.]+)\s+setup skew", section(log, "clock skew"), flags=re.M)
    wire = re.findall(r"Total wire length = (\d+) um", log)
    routed = job.get("droute", True)
    drc = (work / "drc.rpt").read_text().count("violation type:") if routed else ""
    return dict(
        job=name, top=job["top"],
        placement="timing" if job.get("timing_place", True) else "wire length",
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
        drc=drc,
        wire_um=wire[-1] if wire else "",
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
