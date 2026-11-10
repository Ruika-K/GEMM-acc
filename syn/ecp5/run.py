#!/usr/bin/env python3
"""Open-source synthesis and place-and-route for Lattice ECP5.

    python3 syn/ecp5/run.py                 # all jobs
    python3 syn/ecp5/run.py sys_8 bcast_8   # selected jobs
    python3 syn/ecp5/run.py --list

Flow per job:
  1. yowasp-yosys (recent Yosys from PyPI) elaborates the SystemVerilog and
     writes plain Verilog. The distribution Yosys cannot parse the sources.
  2. yosys (distribution package) maps to ECP5 primitives.
  3. nextpnr-ecp5 places, routes and reports the achieved clock frequency.

Place and route is repeated with several seeds, because the result of a single
run moves by several percent with the seed. fmax_mhz is the best seed,
fmax_min_mhz the worst.

Results are written to syn/ecp5/results.csv. The numbers are for an ECP5-85F,
speed grade 8; they show trends and are not comparable with vendor-tool results
for other device families.
"""

import argparse
import csv
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "syn" / "build" / "ecp5"
RESULTS = Path(__file__).resolve().parent / "results.csv"

RTL = sorted((ROOT / "rtl").glob("*.sv"))
ARRAY_SRC = [ROOT / "rtl" / "gemm_pe.sv", ROOT / "rtl" / "gemm_array.sv"] + sorted(
    (ROOT / "syn" / "common").glob("*.sv")
)

DEVICE = ["--85k", "--package", "CABGA756", "--speed", "8"]
TARGET_MHZ = 250   # deliberately out of reach, so every job is pushed equally
SEEDS = (1, 2, 3)
FIELDS = ["job", "top", "params", "mult", "fmax_mhz", "fmax_min_mhz", "lut4", "ff", "mult18",
          "bram", "lutram", "carry", "synth_s", "pnr_s"]


def jobs():
    out = {}
    for n in (2, 4, 8, 12):
        for name, bcast in (("sys", 0), ("bcast", 1)):
            out[f"{name}_{n}"] = dict(
                top="syn_array_harness",
                sources=ARRAY_SRC,
                params={"BCAST": bcast, "ROWS": n, "COLS": n, "PE_PIPE": 1},
            )
    for name, bcast in (("sys", 0), ("bcast", 1)):
        out[f"{name}_8_nopipe"] = dict(
            top="syn_array_harness",
            sources=ARRAY_SRC,
            params={"BCAST": bcast, "ROWS": 8, "COLS": 8, "PE_PIPE": 0},
        )
    # The same arrays with multipliers built from LUTs. ECP5 multiplier blocks
    # sit in a few fixed rows, which hides the effect of the array wiring.
    # 16 x 16 needs 88k LUT4 this way and does not fit the 85F.
    for n in (4, 8, 12):
        for name, bcast in (("sys", 0), ("bcast", 1)):
            out[f"{name}_{n}_lut"] = dict(
                top="syn_array_harness",
                sources=ARRAY_SRC,
                params={"BCAST": bcast, "ROWS": n, "COLS": n, "PE_PIPE": 1},
                nodsp=True,
            )
    out["top_8"] = dict(
        top="gemm_top",
        sources=RTL,
        params={"ROWS": 8, "COLS": 8, "PE_PIPE": 1},
    )
    return out


def sh(cmd, log):
    with open(log, "w") as f:
        subprocess.run([str(c) for c in cmd], stdout=f, stderr=subprocess.STDOUT, check=True)


def cell_counts(synth_log):
    """Cell counts from the last 'Number of cells' block of the Yosys log."""
    counts, grab = {}, False
    for line in synth_log.read_text().splitlines():
        if "Number of cells:" in line:
            counts, grab = {}, True
            continue
        if grab:
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                counts[parts[0]] = int(parts[1])
            elif not line.strip():
                grab = False
    return counts


def run(name, job):
    work = BUILD / name
    work.mkdir(parents=True, exist_ok=True)
    chparam = " ".join(f"-chparam {k} {v}" for k, v in job["params"].items())
    srcs = " ".join(str(s) for s in job["sources"])

    t0 = time.time()
    sh(["yowasp-yosys", "-q", "-p",
        f"read_verilog -sv -DSYNTHESIS {srcs}; hierarchy -top {job['top']} {chparam}; "
        # "memory -nomap" keeps each memory as one object, so its write enables
        # stay grouped per lane instead of being written out bit by bit.
        f"proc; opt; memory -nomap; opt_clean; write_verilog -noattr {work / 'elab.v'}"],
       work / "elab.log")
    sh(["yosys", "-q", "-l", work / "synth.log", "-p",
        f"read_verilog {work / 'elab.v'}; synth_ecp5 {'-nodsp ' if job.get('nodsp') else ''}"
        f"-top {job['top']} -json {work / 'net.json'}"],
       work / "synth.out")
    t1 = time.time()
    fmax = []
    for seed in SEEDS:
        sh(["nextpnr-ecp5", *DEVICE, "--json", work / "net.json", "--freq", TARGET_MHZ,
            "--timing-allow-fail", "--lpf-allow-unconstrained",
            "--report", work / f"pnr_seed{seed}.json", "--seed", seed],
           work / f"pnr_seed{seed}.log")
        rep = json.loads((work / f"pnr_seed{seed}.json").read_text())
        fmax.append(min(v["achieved"] for v in rep["fmax"].values()))
    t2 = time.time()
    cells = cell_counts(work / "synth.log")
    return dict(
        job=name,
        top=job["top"],
        params=" ".join(f"{k}={v}" for k, v in job["params"].items()),
        mult="lut" if job.get("nodsp") else "block",
        fmax_mhz=f"{max(fmax):.1f}",
        fmax_min_mhz=f"{min(fmax):.1f}",
        lut4=cells.get("LUT4", 0),
        ff=cells.get("TRELLIS_FF", 0),
        mult18=cells.get("MULT18X18D", 0),
        bram=cells.get("DP16KD", 0),
        lutram=cells.get("TRELLIS_DPR16X4", 0),
        carry=cells.get("CCU2C", 0),
        synth_s=f"{t1 - t0:.0f}",
        pnr_s=f"{t2 - t1:.0f}",
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
    names = args.names or list(all_jobs)
    for n in names:
        if n not in all_jobs:
            sys.exit(f"unknown job {n}")

    def one(n):
        try:
            row = run(n, all_jobs[n])
            print(f"{n}: {row['fmax_min_mhz']}-{row['fmax_mhz']} MHz, {row['lut4']} LUT4, {row['ff']} FF, "
                  f"{row['mult18']} MULT18, {row['bram']} BRAM", flush=True)
            return row
        except subprocess.CalledProcessError as e:
            print(f"{n}: FAILED ({e.cmd[0]}), see {BUILD / n}", flush=True)
            return None

    with ThreadPoolExecutor(args.jobs) as pool:
        rows = [r for r in pool.map(one, names) if r]

    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = [r for r in csv.DictReader(f) if r["job"] not in {x["job"] for x in rows}]
    merged = sorted(old + rows, key=lambda r: list(all_jobs).index(r["job"])
                    if r["job"] in all_jobs else 999)
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(merged)


if __name__ == "__main__":
    main()
