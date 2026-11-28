#!/usr/bin/env python3
"""Find routed metal pieces below the minimum area of their layer and work
out patches for them, from a DEF file and the technology LEF.

    python3 syn/asic/min_area.py <design.def> <tech.lef> [--layers met3 ...]

The detailed router leaves some of these: a signal that goes up from met2 to
met4 with a short jog on met3 keeps on met3 only the two via landing pads
and the jog (0.19 um2 where met3 needs 0.24 um2). The router reports no
violation; Magic and KLayout both flag them. Each piece is the union of the
wire segments and via pads of one net on one layer that touch each other.

It also fills the outer corner of turns written with an extension of 0,
which leave the shape narrower than the minimum width across the corner.

A patch extends a piece along its longer side, on both ends or on one, until
it has the area; it is only taken if it stays the layer's minimum spacing
away from every shape of another net on that layer (routed wires, via pads,
power stripes, pins). Printed as lines

    PATCH <layer> <x1> <y1> <x2> <y2>     (um)
    UNFIXED <layer> <net> <x1> <y1> <x2> <y2> <area um2>

which signoff.py paints into the layout before DRC and LVS.
"""

import argparse
import math
import re
import sys
from collections import defaultdict


def lef_rules(path):
    """Per layer: default width, minimum area (um2), minimum spacing; per via:
    its rectangles per layer (um, relative to the via origin)."""
    text = open(path).read()
    layers = {}
    for m in re.finditer(r"^LAYER (\S+)(.*?)^END \1", text, flags=re.M | re.S):
        body = m.group(2)
        if not re.search(r"TYPE ROUTING", body):
            continue
        width = re.search(r"^\s*WIDTH ([\d.]+)", body, flags=re.M)
        area = re.search(r"^\s*AREA ([\d.]+)", body, flags=re.M)
        # Minimum spacing by the width of the wider shape: a plain SPACING
        # rule, or the SPACINGTABLE (sky130 has its plain rules commented out
        # and a table instead, met3: 0.3 um, 0.4 um next to shapes 3 um wide
        # and more). The largest value of a row is taken (parallel run length
        # is not looked at, on the safe side).
        table = [(0.0, float(v)) for v in re.findall(r"^\s*SPACING ([\d.]+)\s*;", body, flags=re.M)]
        tm = re.search(r"SPACINGTABLE(.*?);", body, flags=re.S)
        if tm:
            for w, row in re.findall(r"WIDTH\s+([\d.]+)\s+([\d.\s]+)", tm.group(1)):
                table.append((float(w), max(float(v) for v in row.split())))
        table.sort()
        layers[m.group(1)] = dict(width=float(width.group(1)), area=float(area.group(1)) if area else 0.0,
                                  spacing=max((s for _, s in table), default=0.0), table=table)
    vias = {}
    for m in re.finditer(r"^VIA (\S+)(.*?)^END \1", text, flags=re.M | re.S):
        rects = defaultdict(list)
        cur = None
        for line in m.group(2).splitlines():
            lm = re.match(r"\s*LAYER (\S+)", line)
            if lm:
                cur = lm.group(1)
            rm = re.match(r"\s*RECT ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)", line)
            if rm and cur:
                rects[cur].append(tuple(float(v) for v in rm.groups()))
        vias[m.group(1)] = dict(rects)
    return layers, vias


def macro_shapes(lef_paths, want):
    """Pin and obstruction rectangles (um, in the macro's own frame) per
    layer of each macro, and its size."""
    out = {}
    for path in lef_paths:
        text = open(path).read()
        for m in re.finditer(r"^MACRO (\S+)(.*?)^END \1\b", text, flags=re.M | re.S):
            body = m.group(2)
            size = re.search(r"SIZE ([\d.]+) BY ([\d.]+)", body)
            rects = defaultdict(list)
            cur = None
            for line in body.splitlines():
                lm = re.match(r"\s*LAYER (\S+)", line)
                if lm:
                    cur = lm.group(1)
                rm = re.match(r"\s*RECT ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)", line)
                if rm and cur in want:
                    rects[cur].append(tuple(float(v) for v in rm.groups()))
            out[m.group(1)] = (float(size.group(1)), float(size.group(2)), dict(rects))
    return out


def placed_macro_shapes(text, dbu, macros):
    """The shapes of the macros as placed in the DEF, per layer."""
    shapes = defaultdict(list)
    for m in re.finditer(r"- (\S+) (\S+) \+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \) (\S+)", text):
        master = m.group(2)
        if master not in macros:
            continue
        x, y, orient = int(m.group(3)) / dbu, int(m.group(4)) / dbu, m.group(5)
        w, h, rects = macros[master]
        for layer, rs in rects.items():
            for r in rs:
                x1, y1, x2, y2 = r
                if orient in ("S", "FN"):
                    x1, x2 = w - x2, w - x1
                if orient in ("S", "FS"):
                    y1, y2 = h - y2, h - y1
                shapes[layer].append((m.group(1), (x + x1, y + y1, x + x2, y + y2)))
    return shapes


def def_vias(text, dbu):
    """Generated vias of the DEF's VIAS section, as rectangles per layer."""
    vias = {}
    sec = re.search(r"^VIAS \d+ ;(.*?)^END VIAS", text, flags=re.M | re.S)
    if not sec:
        return vias
    for m in re.finditer(r"- (\S+)(.*?);", sec.group(1), flags=re.S):
        body = m.group(2)
        g = re.search(r"\+ CUTSIZE (\d+) (\d+).*?\+ LAYERS (\S+) (\S+) (\S+).*?\+ CUTSPACING (\d+) (\d+)"
                      r".*?\+ ENCLOSURE (\d+) (\d+) (\d+) (\d+)(?:.*?\+ ROWCOL (\d+) (\d+))?", body, flags=re.S)
        if not g:
            continue
        cx, cy = int(g.group(1)), int(g.group(2))
        bot, top = g.group(3), g.group(5)
        sx, sy = int(g.group(6)), int(g.group(7))
        ebx, eby, etx, ety = (int(g.group(i)) for i in range(8, 12))
        rows, cols = int(g.group(12) or 1), int(g.group(13) or 1)
        w = cols * cx + (cols - 1) * sx
        h = rows * cy + (rows - 1) * sy
        vias[m.group(1)] = {
            bot: [(-(w / 2 + ebx) / dbu, -(h / 2 + eby) / dbu, (w / 2 + ebx) / dbu, (h / 2 + eby) / dbu)],
            top: [(-(w / 2 + etx) / dbu, -(h / 2 + ety) / dbu, (w / 2 + etx) / dbu, (h / 2 + ety) / dbu)],
        }
    return vias


def route_shapes(text, section, layers, vias, dbu, want):
    """Rectangles (um) per (net, layer) of the routing in a DEF section."""
    shapes = defaultdict(list)
    sec = re.search(rf"^{section} \d+ ;(.*?)^END {section}", text, flags=re.M | re.S)
    if not sec:
        return shapes
    for m in re.finditer(r"^\s*- (\S+)(.*?);\s*$", sec.group(1), flags=re.M | re.S):
        net, body = m.group(1), m.group(2)
        for part in re.split(r"\+ (?:ROUTED|FIXED|COVER|NOSHIELD)|\bNEW\b", body)[1:]:
            toks = re.findall(r"\(|\)|[^\s()]+", part)
            if not toks:
                continue
            layer = toks[0]
            i, width = 1, None
            if i < len(toks) and re.fullmatch(r"\d+", toks[i] or ""):
                width = int(toks[i]) / dbu          # SPECIALNETS: width after the layer
                i += 1
            if width is None:
                width = layers.get(layer, {}).get("width", 0.0)
            pts = []
            last = None
            while i < len(toks):
                t = toks[i]
                if t == "(":
                    j = toks.index(")", i)
                    vals = toks[i + 1:j]
                    x = last[0] if vals[0] == "*" else int(vals[0]) / dbu
                    y = last[1] if vals[1] == "*" else int(vals[1]) / dbu
                    ext = int(vals[2]) / dbu if len(vals) > 2 else None
                    if last is not None and layer in want:
                        e1 = width / 2 if last[2] is None else last[2]
                        e2 = width / 2 if ext is None else ext
                        x1, x2 = sorted((last[0], x))
                        y1, y2 = sorted((last[1], y))
                        if x1 == x2:
                            shapes[(net, layer)].append((x1 - width / 2, y1 - e1, x2 + width / 2, y2 + e2))
                        else:
                            shapes[(net, layer)].append((x1 - e1, y1 - width / 2, x2 + e2, y2 + width / 2))
                    last = (x, y, ext)
                    pts.append(last)
                    i = j + 1
                elif t == "RECT":
                    j = toks.index(")", i + 1)
                    a = [int(v) / dbu for v in toks[i + 2:j]]
                    if last is not None and layer in want:
                        shapes[(net, layer)].append((last[0] + a[0], last[1] + a[1], last[0] + a[2], last[1] + a[3]))
                    i = j + 1
                elif t in vias:
                    if last is not None:
                        for vl, rects in vias[t].items():
                            if vl in want:
                                for r in rects:
                                    shapes[(net, vl)].append((last[0] + r[0], last[1] + r[1], last[0] + r[2], last[1] + r[3]))
                    # The route goes on on the via's other routing layer.
                    other = [vl for vl in vias[t] if vl in layers and vl != layer]
                    if other:
                        layer = other[0]
                        width = layers[layer]["width"]
                    i += 1
                else:
                    i += 1
    return shapes


def zero_ext_corners(text, layers, vias, dbu, want):
    """Corners where a route turns at a point written with an extension of
    0 ("( * y 0 )"): both wires stop at the centre line, the outer corner is
    cut by half a width on each side, and the shape is narrower than the
    minimum width across the cut (KLayout's euclidean m2.1). Returns
    (net, layer, square of the wire's width at the corner)."""
    out = []
    sec = re.search(r"^NETS \d+ ;(.*?)^END NETS", text, flags=re.M | re.S)
    if not sec:
        return out
    for m in re.finditer(r"^\s*- (\S+)(.*?);\s*$", sec.group(1), flags=re.M | re.S):
        net, body = m.group(1), m.group(2)
        for part in re.split(r"\+ (?:ROUTED|FIXED|COVER|NOSHIELD)|\bNEW\b", body)[1:]:
            toks = re.findall(r"\(|\)|[^\s()]+", part)
            if not toks:
                continue
            layer = toks[0]
            events, last, i = [], None, 1
            while i < len(toks):
                t = toks[i]
                if t == "(":
                    j = toks.index(")", i)
                    vals = toks[i + 1:j]
                    x = last[0] if vals[0] == "*" else int(vals[0]) / dbu
                    y = last[1] if vals[1] == "*" else int(vals[1]) / dbu
                    ext = int(vals[2]) / dbu if len(vals) > 2 else None
                    last = (x, y)
                    events.append(("pt", x, y, ext, layer))
                    i = j + 1
                elif t in vias:
                    events.append(("via",))
                    other = [vl for vl in vias[t] if vl in layers and vl != layer]
                    if other:
                        layer = other[0]
                    i += 1
                elif t == "RECT":
                    i = toks.index(")", i + 1) + 1
                else:
                    i += 1
            for k in range(1, len(events) - 1):
                # The point before: a via in between sits at that point and
                # only changes the layer the segment to this one is on.
                j = k - 1
                while j >= 0 and events[j][0] == "via":
                    j -= 1
                if j < 0:
                    continue
                a, b, c = events[j], events[k], events[k + 1]
                if b[0] != "pt" or c[0] != "pt" or b[3] != 0 or b[4] not in want:
                    continue
                d1 = (b[1] - a[1], b[2] - a[2])
                d2 = (c[1] - b[1], c[2] - b[2])
                if (d1[0] == 0) == (d2[0] == 0):          # not a turn
                    continue
                w = layers[b[4]]["width"] / 2
                out.append((net, b[4], (b[1] - w, b[2] - w, b[1] + w, b[2] + w)))
    return out


def components(rects):
    """Groups of touching rectangles."""
    n = len(rects)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for a in range(n):
        for b in range(a + 1, n):
            ra, rb = rects[a], rects[b]
            if ra[0] <= rb[2] and rb[0] <= ra[2] and ra[1] <= rb[3] and rb[1] <= ra[3]:
                parent[find(a)] = find(b)
    groups = defaultdict(list)
    for a in range(n):
        groups[find(a)].append(rects[a])
    return list(groups.values())


def union_area(rects):
    xs = sorted({v for r in rects for v in (r[0], r[2])})
    ys = sorted({v for r in rects for v in (r[1], r[3])})
    area = 0.0
    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
            if any(r[0] <= cx <= r[2] and r[1] <= cy <= r[3] for r in rects):
                area += (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
    return area


def snap(v, grid=0.005, up=True):
    return (math.ceil if up else math.floor)(round(v / grid, 6)) * grid


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("def_file")
    ap.add_argument("tech_lef")
    ap.add_argument("--layers", nargs="*", default=["met1", "met2", "met3", "met4"])
    ap.add_argument("--macro-lef", nargs="*", default=[],
                    help="LEF files of macros placed in the design: their pins and obstructions count as other shapes")
    args = ap.parse_args()
    text = open(args.def_file).read()
    dbu = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", text).group(1))
    layers, vias = lef_rules(args.tech_lef)
    vias.update(def_vias(text, dbu))
    want = set(args.layers)
    signal = route_shapes(text, "NETS", layers, vias, dbu, want)
    special = route_shapes(text, "SPECIALNETS", layers, vias, dbu, want)
    # Every shape per layer, for the spacing check, in buckets of 2 um; the
    # pins and obstructions of macros count as shapes of other nets.
    macro = placed_macro_shapes(text, dbu, macro_shapes(args.macro_lef, want))
    extra = [((f"macro:{inst}", layer), [r]) for layer, items in macro.items() for inst, r in items]
    bucket = defaultdict(list)
    for (net, layer), rects in list(signal.items()) + list(special.items()) + extra:
        for r in rects:
            for bx in range(int(r[0] // 2), int(r[2] // 2) + 1):
                for by in range(int(r[1] // 2), int(r[3] // 2) + 1):
                    bucket[(layer, bx, by)].append((net, r))

    def spacing(layer, a, b):
        w = max(min(a[2] - a[0], a[3] - a[1]), min(b[2] - b[0], b[3] - b[1]))
        sp = 0.0
        for wmin, s in layers[layer]["table"]:
            if w >= wmin:
                sp = s
        return sp

    def clear(layer, net, r, sp):
        for bx in range(int((r[0] - sp) // 2), int((r[2] + sp) // 2) + 1):
            for by in range(int((r[1] - sp) // 2), int((r[3] + sp) // 2) + 1):
                for other, o in bucket.get((layer, bx, by), ()):
                    if other == net:
                        continue
                    s = spacing(layer, r, o)
                    if r[0] - s < o[2] and o[0] < r[2] + s and r[1] - s < o[3] and o[1] < r[3] + s:
                        return False
        return True

    found = fixed = 0
    for (net, layer), rects in sorted(signal.items()):
        rule = layers[layer]
        if rule["area"] <= 0:
            continue
        for comp in components(rects):
            a = union_area(comp)
            if a >= rule["area"] - 1e-9:
                continue
            found += 1
            x1, y1 = min(r[0] for r in comp), min(r[1] for r in comp)
            x2, y2 = max(r[2] for r in comp), max(r[3] for r in comp)
            w, h = x2 - x1, y2 - y1
            # The patch: the bounding box, longer along its long side by what
            # the area needs (with some margin), against the bounding box's area.
            need = rule["area"] * 1.05
            done = None
            # Candidates: longer along either side, the extension split between
            # the two ends in steps of a fifth; then wider across.
            cands = []
            for horizontal in ((True, False) if w >= h else (False, True)):
                if horizontal:
                    ext = snap(max(0.0, need / h - w))
                    for k in (0.5, 0.0, 1.0, 0.2, 0.8, 0.4, 0.6):
                        lo = snap(ext * k)
                        cands.append((x1 - lo, y1, x2 + snap(ext - lo), y2))
                else:
                    ext = snap(max(0.0, need / w - h))
                    for k in (0.5, 0.0, 1.0, 0.2, 0.8, 0.4, 0.6):
                        lo = snap(ext * k)
                        cands.append((x1, y1 - lo, x2, y2 + snap(ext - lo)))
            for c in cands:
                if clear(layer, net, c, rule["spacing"]):
                    done = c
                    break
            if done:
                fixed += 1
                print(f"PATCH {layer} {done[0]:.3f} {done[1]:.3f} {done[2]:.3f} {done[3]:.3f}")
            else:
                print(f"UNFIXED {layer} {net} {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f} {a:.4f}")
    print(f"# {found} pieces below the minimum area, {fixed} patched", file=sys.stderr)
    corners = zero_ext_corners(text, layers, vias, dbu, want)
    filled = 0
    for net, layer, sq in corners:
        if clear(layer, net, sq, layers[layer]["spacing"]):
            filled += 1
            print(f"PATCH {layer} {sq[0]:.3f} {sq[1]:.3f} {sq[2]:.3f} {sq[3]:.3f}")
        else:
            print(f"UNFIXED {layer} {net} {sq[0]:.3f} {sq[1]:.3f} {sq[2]:.3f} {sq[3]:.3f} corner")
    print(f"# {len(corners)} corners without extension, {filled} filled", file=sys.stderr)


if __name__ == "__main__":
    main()
