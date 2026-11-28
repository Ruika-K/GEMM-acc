#!/usr/bin/env python3
"""Static IR drop of the routed chip and of the PE macro inside it.

    python3 syn/asic/ir_drop.py chip_8_m4            # the analysis
    python3 syn/asic/ir_drop.py chip_8_m4 --parse    # only re-read the reports

Needs the routed PE macro and chip (pnr.py pe_m4_macro chip_8_m4) and the
switching activity of the compute workload (power.py chip_8_m4 compute
--keep-vcd; run here if its VCD file is missing).

IR drop is the voltage the supply loses on its way through the power grid to
the cells: every cell draws current, every stripe, rail and via has
resistance. PDNSim (ir_drop.tcl) solves the resistor network of the grid
with the average current of every instance, for VPWR (how far the supply
falls) and VGND (how far ground rises). It is a static analysis: average
currents, no peaks within a cycle.

* Currents: the power of each instance at the typical corner with the
  activity of the compute workload (16 full tiles, the heaviest the chip
  sees), as power.py, at the 100 MHz of the simulation. The PE macros carry no
  power in their timing model, so each gets its own from the power analysis
  (power.tcl, which reads their netlists). The SRAMs draw what their models
  say, which charges a full access on every clock edge, selected or not: an
  upper end. The grid is a linear network, so the drop scales with the
  current; dynamic power scales with the clock (leakage is 0.2 mW of
  221 mW), and the drop at the slow-corner frequency is the drop at 100 MHz
  times f / 100 MHz.
* The chip has no pads; two ways of feeding it are analysed. "bumps": a
  flip-chip bump array over the die (PDNSim's default, 140 um pitch, every
  third bump a supply). "edge": the supply enters only at the edges of the
  core, as from a pad ring (and as a block inside a padframe such as
  Caravel's gets it): at the ends of the met5 stripes on the left and right,
  and along the met5 segments of the power ring at the top and bottom.
* Inside the PE: the chip-level analysis sees a PE as a current drawn where
  the chip's met5 stripes connect to the PE's met4 straps. The drop from
  there to the cells inside comes from the PE's own layout, with its own
  activity (the PE that draws the most), and sources exactly at those
  connections.
* What it costs in frequency: the flat timing analysis again with the
  slow-corner library at 1.40 V instead of 1.60 V (sta_flat.tcl,
  STA_SS_LIB), interpolated linearly to 1.60 V minus the worst drop of VPWR
  and VGND together. Every cell is given the worst drop, which is
  pessimistic.

Results in syn/asic/ir_results.csv, reports in
syn/build/asic/<job dir>/ir_drop/, a map of the drop in docs/<job>_ir.svg.
"""

import argparse
import csv
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pnr  # noqa: E402

ROOT = HERE.parents[1]
REF = Path(pnr.PDK_ROOT) / "sky130A" / "libs.ref" / "sky130_fd_sc_hd" / "lib"
TT_LIB = REF / "sky130_fd_sc_hd__tt_025C_1v80.lib"
SS_LIB_LOW = REF / "sky130_fd_sc_hd__ss_100C_1v40.lib"
V_SS, V_SS_LOW = 1.60, 1.40
RESULTS = HERE / "ir_results.csv"
FIELDS = ["job", "case", "sources", "clk_mhz", "power_mw",
          "vpwr_worst_mv", "vpwr_avg_mv", "vgnd_worst_mv", "vgnd_avg_mv",
          "pe_internal_mv", "total_worst_mv", "fmax_ss_mhz", "fmax_ss_low_mhz", "fmax_ss_ir_mhz"]


def openroad():
    return os.environ.get("OPENROAD") or "openroad"


class Job:
    def __init__(self, name):
        self.name = name
        self.job = pnr.jobs()[name]
        self.work = pnr.dirs(name, self.job)[1]
        self.mjob = pnr.jobs()[self.job["hier"]]
        self.mdir = pnr.dirs(self.job["hier"], self.mjob)[1]
        self.cell = self.mjob["top"]
        self.top = self.job["top"]
        self.out = self.work / "ir_drop"
        self.vcd = self.work / "power" / "compute.vcd"
        self.power_log = self.work / "power" / "compute.log"


# ----------------------------------------------------------------------------
# Layout geometry from DEF and LEF (um)

def def_scale(text):
    return int(re.search(r"UNITS DISTANCE MICRONS (\d+)", text).group(1))


def special_stripes(def_text, net, layer, shapes="STRIPE"):
    """Stripes (or ring segments, shapes="RING") of a special net on one
    layer: (x1, y1, x2, y2) of the centre line and the width."""
    s = def_scale(def_text)
    body = re.search(r"^SPECIALNETS.*?^END SPECIALNETS", def_text, flags=re.M | re.S).group(0)
    m = re.search(rf"^\s*- {net}\b(.*?);\s*$", body, flags=re.M | re.S)
    out = []
    for w in re.finditer(rf"{layer} (\d+) \+ SHAPE (?:{shapes}) \( (-?\d+) (-?\d+) \) \( (\*|-?\d+) (\*|-?\d+) \)", m.group(1)):
        width, x1, y1 = int(w.group(1)), int(w.group(2)), int(w.group(3))
        x2 = x1 if w.group(4) == "*" else int(w.group(4))
        y2 = y1 if w.group(5) == "*" else int(w.group(5))
        out.append((x1 / s, y1 / s, x2 / s, y2 / s, width / s))
    return out


def edge_sources(def_text, net, voltage, step=10.0):
    """Supply at the edges of the core: the ends of the net's met5 stripes at
    the left and right edge, and, with a power ring, points every `step` um
    along its met5 segments at the top and bottom (PDNSim takes sources on
    the top layer only; the met4 sides of the ring are fed through the
    stripe ends on them)."""
    st = [t for t in special_stripes(def_text, net, "met5") if t[1] == t[3]]
    left = min(min(t[0], t[2]) for t in st)
    right = max(max(t[0], t[2]) for t in st)
    pts = []
    for x1, y, x2, _, w in st:
        lo, hi = min(x1, x2), max(x1, x2)
        if lo - left < 1.0:
            pts.append((lo + w / 2, y, w, voltage))
        if right - hi < 1.0:
            pts.append((hi - w / 2, y, w, voltage))
    for x1, y, x2, y2, w in special_stripes(def_text, net, "met5", "RING"):
        if y != y2:
            continue
        x = min(x1, x2)
        while x <= max(x1, x2):
            pts.append((x, y, w, voltage))
            x += step
    return pts


def macro_origin(def_text, inst):
    s = def_scale(def_text)
    esc = re.escape(inst.replace("[", "\\[").replace("]", "\\]"))
    m = re.search(rf"^\s*- {esc} \S+ \+ (?:FIXED|PLACED) \( (\d+) (\d+) \) (\S+)", def_text, flags=re.M)
    if m.group(3) != "N":
        raise RuntimeError(f"{inst}: orientation {m.group(3)} not handled")
    return int(m.group(1)) / s, int(m.group(2)) / s


def lef_pin_rects(lef_text, pin, layer):
    body = re.search(rf"^\s*PIN {pin}\b(.*?)^\s*END {pin}\b", lef_text, flags=re.M | re.S).group(1)
    rects, cur = [], None
    for line in body.splitlines():
        m = re.match(r"\s*LAYER (\S+)", line)
        if m:
            cur = m.group(1)
        m = re.match(r"\s*RECT\s+(\S+) (\S+) (\S+) (\S+)", line)
        if m and cur == layer:
            rects.append(tuple(float(v) for v in m.groups()))
    return rects


def pe_sources(j, inst, net, voltage):
    """Where the chip's met5 stripes of the net cross the PE's met4 straps, in
    the PE's coordinates."""
    d = (j.work / f"{j.top}.def").read_text()
    ox, oy = macro_origin(d, inst)
    straps = lef_pin_rects((j.mdir / f"{j.cell}.lef").read_text(), net, "met4")
    pts = []
    for x1, y, x2, y2, w in special_stripes(d, net, "met5"):
        if y != y2:
            continue
        for sx1, sy1, sx2, sy2 in straps:
            gx = ox + (sx1 + sx2) / 2
            if min(x1, x2) <= gx <= max(x1, x2) and oy + sy1 <= y <= oy + sy2:
                pts.append(((sx1 + sx2) / 2, y - oy, sx2 - sx1, voltage))
    if not pts:
        raise RuntimeError(f"{inst}: no met5 stripe of {net} crosses its straps")
    return pts


def write_vsrc(path, pts):
    path.write_text("".join(f"{x:.3f},{y:.3f},{s:.3f},{v}\n" for x, y, s, v in pts))


# ----------------------------------------------------------------------------
# Power per instance from the power analysis (power.tcl's instance section)

def instance_power(j):
    log = j.power_log.read_text()
    sec = re.search(r"^SECTION instances$(.*?)^SECTION ", log, flags=re.M | re.S).group(1)
    p = {}
    for m in re.finditer(r"^\s*[-\d.e+]+\s+[-\d.e+]+\s+[-\d.e+]+\s+([-\d.e+]+)\s+(\S+)$", sec, flags=re.M):
        p[m.group(2).replace("\\", "")] = float(m.group(1))
    return p


# ----------------------------------------------------------------------------

def run_ir(j, env, log):
    with open(log, "w") as f:
        subprocess.run([openroad(), "-no_init", "-exit", str(HERE / "ir_drop.tcl")],
                       stdout=f, stderr=subprocess.STDOUT, check=True, cwd=j.out,
                       env=dict(os.environ, PDK_ROOT=pnr.PDK_ROOT, **env))


def analyse(j):
    if not j.vcd.exists() or "SECTION end" not in j.power_log.read_text():
        subprocess.run([sys.executable, str(HERE / "power.py"), j.name, "compute", "--keep-vcd"], check=True)
    j.out.mkdir(exist_ok=True)
    clk_ns = 1000 / 100
    m = re.search(r'"clk_ns":\s*([0-9.]+)', (j.work / "power" / "compute.json").read_text())
    if m:
        clk_ns = float(m.group(1))
    d = (j.work / f"{j.top}.def").read_text()

    # Chip: the PEs' power given per instance.
    power = instance_power(j)
    pes = {k: v for k, v in power.items() if k.endswith(".u_pe")}
    (j.out / "pe_power.txt").write_text("".join(f"{k} {v:.6e}\n" for k, v in sorted(pes.items())))
    for net, v in (("VPWR", 1.8), ("VGND", 0.0)):
        write_vsrc(j.out / f"edge_{net}.vsrc", edge_sources(d, net, v))
    libs = [TT_LIB, j.mdir / f"{j.cell}_tt.lib"] + [j.work / f.name for f in pnr.SRAM_LIBS]
    run_ir(j, dict(IR_LIBS=" ".join(map(str, libs)), IR_DB=str(j.work / f"{j.top}.odb"),
                   IR_SDC=str(j.work / "constraints.sdc"), IR_SPEF=str(j.work / f"{j.top}.spef"),
                   IR_CLOCK_PORT="aclk", IR_PERIOD=str(clk_ns), IR_VCD=str(j.vcd),
                   IR_SCOPE="gemm_top_gls/u_netlist", IR_INST_POWER=str(j.out / "pe_power.txt"),
                   IR_CASES=f"bumps BUMPS edge {j.out}/edge_%NET%.vsrc", IR_OUT=str(j.out)),
           j.out / "chip.log")

    # The PE that draws the most, on its own.
    pe = max(pes, key=pes.get)
    for net, v in (("VPWR", 1.8), ("VGND", 0.0)):
        write_vsrc(j.out / f"pe_{net}.vsrc", pe_sources(j, pe, net, v))
    (j.out / "pe_instance.txt").write_text(pe + "\n")
    run_ir(j, dict(IR_LIBS=str(TT_LIB), IR_DB=str(j.mdir / f"{j.cell}.odb"),
                   IR_SDC=str(j.mdir / "constraints.sdc"), IR_SPEF=str(j.mdir / f"{j.cell}.spef"),
                   IR_CLOCK_PORT="clk", IR_PERIOD=str(clk_ns), IR_VCD=str(j.vcd),
                   IR_SCOPE=f"gemm_top_gls/u_netlist/{pe}",
                   IR_CASES=f"pe {j.out}/pe_%NET%.vsrc", IR_OUT=str(j.out)),
           j.out / "pe.log")

    # Timing at the lower supply of the slow corner.
    os.environ["STA_SS_LIB"] = str(SS_LIB_LOW)
    try:
        pnr.sta_flat(j.job, j.work, j.mdir, j.cell, log=j.out / "sta_flat_1v40.log")
    finally:
        del os.environ["STA_SS_LIB"]


def ir_report(log, case, net):
    sec = re.search(rf"^SECTION ir {case} {net}$(.*?)^SECTION ", log, flags=re.M | re.S)
    if not sec:
        raise RuntimeError(f"no IR report for {case} {net}")
    t = sec.group(1)
    if "Worstcase IR drop" not in t:
        raise RuntimeError(f"{case} {net}: analysis failed:\n{t[-2000:]}")
    worst = float(re.search(r"Worstcase IR drop:\s*(\S+) V", t).group(1))
    avg = float(re.search(r"Average IR drop\s*:\s*(\S+) V", t).group(1))
    power = float(re.search(r"Total power\s*:\s*(\S+) W", t).group(1))
    return worst, avg, power


def fmax_ss(timing, period):
    sec = re.search(r"^SECTION setup_r2r ss$(.*?)^SECTION ", timing, flags=re.M | re.S).group(1)
    return 1000 / (period - pnr.slack(sec))


def parse(j):
    chip = (j.out / "chip.log").read_text()
    pe = (j.out / "pe.log").read_text()
    for name, text in (("chip", chip), ("pe", pe)):
        if "SECTION end" not in text:
            raise RuntimeError(f"{name}: IR drop analysis stopped early")
        listed = re.search(r"^Unannotated pins:\n(.*?)^SECTION unannotated end", text, flags=re.M | re.S)
        if listed is None or listed.group(1).strip():
            raise RuntimeError(f"{name}: pins without activity from the VCD file")
    period = float(re.search(r"-period\s+([0-9.]+)", (j.work / "constraints.sdc").read_text()).group(1))
    f_ss = fmax_ss((j.work / "sta_flat.log").read_text(), period)
    f_low = fmax_ss((j.out / "sta_flat_1v40.log").read_text(), period)
    clk = 1000 / float(re.search(r'"clk_ns":\s*([0-9.]+)', (j.work / "power" / "compute.json").read_text()).group(1))

    pe_w = [ir_report(pe, "pe", n) for n in ("VPWR", "VGND")]
    pe_int = pe_w[0][0] + pe_w[1][0]
    rows = []
    for case, sources in (("bumps", "flip-chip bumps, 140 um pitch, every third"),
                          ("edge", "core edges: met5 stripe ends and power ring")):
        vp = ir_report(chip, case, "VPWR")
        vg = ir_report(chip, case, "VGND")
        for f in (clk, f_ss):
            k = f / clk
            total = (vp[0] + vg[0] + pe_int) * k
            # Linear in the supply between the two libraries; beyond the lower
            # one there is nothing to interpolate from.
            f_ir = f_ss + (f_low - f_ss) * total / (V_SS - V_SS_LOW)
            f_ir = f"{f_ir:.1f}" if total <= V_SS - V_SS_LOW else f"<{f_low:.0f}"
            rows.append(dict(job=j.name, case=case, sources=sources, clk_mhz=f"{f:.0f}",
                             power_mw=f"{vp[2] * k * 1e3:.1f}",
                             vpwr_worst_mv=f"{vp[0] * k * 1e3:.2f}", vpwr_avg_mv=f"{vp[1] * k * 1e3:.2f}",
                             vgnd_worst_mv=f"{vg[0] * k * 1e3:.2f}", vgnd_avg_mv=f"{vg[1] * k * 1e3:.2f}",
                             pe_internal_mv=f"{pe_int * k * 1e3:.2f}", total_worst_mv=f"{total * 1e3:.2f}",
                             fmax_ss_mhz=f"{f_ss:.0f}", fmax_ss_low_mhz=f"{f_low:.0f}",
                             fmax_ss_ir_mhz=f_ir if f == f_ss else ""))
    return rows


def save(rows):
    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = list(csv.DictReader(f))
    jobs = {r["job"] for r in rows}
    merged = [r for r in old if r["job"] not in jobs] + rows
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(merged)


# ----------------------------------------------------------------------------
# Map of the drop over the die (VPWR drop plus VGND rise, per bin)

def drop_map(j, case, svg, k, bin_um=40.0):
    d = (j.work / f"{j.top}.def").read_text()
    s = def_scale(d)
    die = re.search(r"DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)", d)
    W, H = int(die.group(3)) / s, int(die.group(4)) / s
    nx, ny = int(W // bin_um) + 1, int(H // bin_um) + 1
    worst = {}
    for net in ("VPWR", "VGND"):
        b = defaultdict(float)
        with open(j.out / f"{case}_{net}.csv") as f:
            next(f)
            for line in f:
                p = line.rstrip().split(",")
                v = float(p[5])
                drop = 1.8 - v if net == "VPWR" else v
                key = (int(float(p[3]) // bin_um), int(float(p[4]) // bin_um))
                b[key] = max(b[key], drop)
        for key, v in b.items():
            worst[key] = worst.get(key, 0.0) + v
    top = max(worst.values()) * k * 1e3
    # Macros as outlines.
    comps = re.findall(r"^\s*- (\S+) (gemm_pe|sky130_sram_\S+) \+ FIXED \( (\d+) (\d+) \) (\S+)", d, flags=re.M)
    sizes = {}
    for lef in [j.mdir / f"{j.cell}.lef"] + [pnr.SRAM_REF / "lef" / f"{m}.lef" for m in pnr.SRAM_MACROS]:
        t = lef.read_text()
        for m in re.finditer(r"^MACRO (\S+)(.*?)^END\s+\1", t, flags=re.M | re.S):
            sz = re.search(r"SIZE (\S+) BY (\S+)", m.group(2))
            sizes[m.group(1)] = (float(sz.group(1)), float(sz.group(2)))
    sc = 600 / max(W, H)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W * sc + 140:.0f}" height="{H * sc + 40:.0f}" '
           f'font-family="sans-serif" font-size="11">',
           f'<rect x="0" y="0" width="100%" height="100%" fill="white"/>',
           f'<rect x="0" y="0" width="{W * sc:.1f}" height="{H * sc:.1f}" fill="#f4f4f4"/>']

    def color(t):
        # white -> yellow -> red -> dark red
        stops = [(0.0, (255, 255, 255)), (0.35, (253, 215, 90)), (0.7, (230, 80, 40)), (1.0, (120, 0, 20))]
        for (a, ca), (b2, cb) in zip(stops, stops[1:]):
            if t <= b2:
                u = (t - a) / (b2 - a)
                return "#%02x%02x%02x" % tuple(round(ca[i] + (cb[i] - ca[i]) * u) for i in range(3))
        return "#780014"
    for (ix, iy), v in worst.items():
        mv = v * k * 1e3
        out.append(f'<rect x="{ix * bin_um * sc:.1f}" y="{(H - (iy + 1) * bin_um) * sc:.1f}" '
                   f'width="{bin_um * sc + 0.3:.1f}" height="{bin_um * sc + 0.3:.1f}" fill="{color(mv / top)}"/>')
    for name, cell, x, y, _ in comps:
        w, h = sizes[cell]
        x, y = int(x) / s, int(y) / s
        out.append(f'<rect x="{x * sc:.1f}" y="{(H - y - h) * sc:.1f}" width="{w * sc:.1f}" height="{h * sc:.1f}" '
                   f'fill="none" stroke="#555" stroke-width="0.5"/>')
    lx = W * sc + 20
    for i in range(11):
        t = 1 - i / 10
        out.append(f'<rect x="{lx:.0f}" y="{20 + i * 20}" width="18" height="20" fill="{color(t)}"/>')
        out.append(f'<text x="{lx + 24:.0f}" y="{34 + i * 20}">{t * top:.1f} mV</text>')
    out.append(f'<text x="{lx:.0f}" y="12">drop + bounce</text>')
    out.append(f'<text x="0" y="{H * sc + 16:.0f}">Static IR drop of VPWR plus ground bounce of VGND, worst per {bin_um:.0f} um square, '
               f'{case} feed, at {k * 100:.0f} MHz; macros in grey</text>')
    out.append("</svg>")
    svg.write_text("\n".join(out) + "\n")
    return top


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("job")
    ap.add_argument("--parse", action="store_true", help="only read the existing reports")
    args = ap.parse_args()
    j = Job(args.job)
    if not args.parse:
        analyse(j)
    rows = parse(j)
    save(rows)
    for r in rows:
        print(", ".join(f"{k}={v}" for k, v in r.items()))
    f_ss = float(rows[1]["fmax_ss_mhz"])
    clk = float(rows[0]["clk_mhz"])
    for case in ("edge",):
        top = drop_map(j, case, ROOT / "docs" / f"{j.name}_ir.svg", f_ss / clk)
        print(f"map: {case}, worst bin {top:.1f} mV at {f_ss:.0f} MHz (chip level, without the PE inside)")


if __name__ == "__main__":
    main()
