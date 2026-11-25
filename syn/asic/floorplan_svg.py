#!/usr/bin/env python3
"""Draw a placed and routed block as an SVG picture: macros as labelled boxes,
standard cells as a density map. No dependencies beyond the standard library.

    python3 syn/asic/floorplan_svg.py <design.def> <out.svg> <lef> [<lef> ...]

The LEF files give the sizes of the cells (standard cell library and macros).
"""

import re
import sys
from collections import defaultdict

BIN_UM = 20.0       # density map resolution
SCALE = 0.25        # SVG units per um


def lef_sizes(paths):
    sizes = {}
    for path in paths:
        text = open(path).read()
        for m in re.finditer(r"^MACRO (\S+)(.*?)^END\s+\1\b", text, flags=re.M | re.S):
            s = re.search(r"SIZE ([\d.]+) BY ([\d.]+)", m.group(2))
            if s:
                sizes[m.group(1)] = (float(s.group(1)), float(s.group(2)))
    return sizes


def components(def_text):
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", def_text).group(1))
    die = [int(v) / dbu for v in re.search(r"DIEAREA \( (\d+) (\d+) \) \( (\d+) (\d+) \)", def_text).groups()]
    section = re.search(r"^COMPONENTS \d+ ;(.*?)^END COMPONENTS", def_text, flags=re.M | re.S).group(1)
    comps = []
    for m in re.finditer(r"- (\S+) (\S+)(.*?);", section, flags=re.S):
        loc = re.search(r"\+ (?:PLACED|FIXED|FIRM|COVER) \( (-?\d+) (-?\d+) \) (\S+)", m.group(3))
        if loc:
            comps.append((m.group(1), m.group(2), int(loc.group(1)) / dbu, int(loc.group(2)) / dbu, loc.group(3)))
    return die, comps


def label(name, master):
    if master.startswith("sky130_sram"):
        mem = re.search(r"u_(a|b|bias)_mem", name)
        return f"{mem.group(1).upper() if mem else 'SRAM'}"
    return ""


def main():
    def_path, svg_path, *lefs = sys.argv[1:]
    sizes = lef_sizes(lefs)
    die, comps = components(open(def_path).read())
    w, h = die[2] - die[0], die[3] - die[1]
    macros, density = [], defaultdict(float)
    for name, master, x, y, orient in comps:
        sw, sh = sizes.get(master, (0.0, 0.0))
        if orient in ("W", "E", "FW", "FE"):
            sw, sh = sh, sw
        if sw * sh > 2000:                       # a macro
            macros.append((name, master, x, y, sw, sh))
        elif "FILLER" not in name and "TAP" not in name and "decap" not in master and "fill" not in master:
            density[(int(x // BIN_UM), int(y // BIN_UM))] += sw * sh
    peak = max(density.values()) if density else 1.0

    def X(v):
        return f"{v * SCALE:.1f}"

    def Y(v, height=0.0):      # SVG y grows downwards
        return f"{(h - v - height) * SCALE:.1f}"

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{X(w)}" height="{X(h)}" '
           f'viewBox="0 0 {X(w)} {X(h)}" font-family="sans-serif">',
           f'<rect width="{X(w)}" height="{X(h)}" fill="#ffffff" stroke="#000000"/>']
    for (bx, by), area in density.items():
        level = min(1.0, area / peak)
        shade = int(235 - 175 * level)
        out.append(f'<rect x="{X(bx * BIN_UM)}" y="{Y(by * BIN_UM, BIN_UM)}" width="{X(BIN_UM)}" '
                   f'height="{X(BIN_UM)}" fill="rgb({shade},{shade},{shade + 15 if shade < 240 else 255})"/>')
    for name, master, x, y, sw, sh in macros:
        sram = master.startswith("sky130_sram")
        fill = "#f2c38b" if sram else "#8fb8de"
        out.append(f'<rect x="{X(x)}" y="{Y(y, sh)}" width="{X(sw)}" height="{X(sh)}" '
                   f'fill="{fill}" stroke="#333333" stroke-width="0.5"/>')
        text = label(name, master)
        if text:
            out.append(f'<text x="{X(x + sw / 2)}" y="{Y(y + sh / 2)}" font-size="{40 * SCALE:.0f}" '
                       f'text-anchor="middle" dominant-baseline="middle">{text}</text>')
    out.append(f'<text x="{X(20)}" y="{X(h - 20)}" font-size="{36 * SCALE:.0f}">'
               f'{w / 1000:.2f} x {h / 1000:.2f} mm. Blue: PE macros. Orange: SRAM macros. '
               f'Grey: standard cell density.</text>')
    out.append("</svg>")
    open(svg_path, "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
