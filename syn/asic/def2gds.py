# ------------------------------------------------------------------------------
# DEF to GDS with KLayout (run by signoff.py: klayout -b -r def2gds.py -rd ...).
#
# The routing and vias come from the DEF, drawn on the layers of the PDK's
# LEF/DEF layer map; the cells (standard cells, SRAMs, the PE macro) are
# placed as empty cells first and then filled with their layouts from GDS
# files. Patches (rectangles, see min_area.py) are drawn into the top cell.
#
#   -rd def=<file> -rd out=<file> -rd map=<layer map>
#   -rd lefs="<lef> ..." -rd gds="<gds> ..." -rd patches=<file, optional>
# ------------------------------------------------------------------------------
import pya

ly = pya.Layout()
opt = pya.LoadLayoutOptions()
cfg = opt.lefdef_config
cfg.map_file = map
cfg.read_lef_with_def = False
cfg.lef_files = lefs.split()
cfg.macro_resolution_mode = 1        # cells from GDS, not from LEF geometry
cfg.dbu = 0.001
ly.read(globals()["def"], opt)
top = ly.top_cell()
top_name = top.name

for g in gds.split():
    o = pya.LoadLayoutOptions()
    o.cell_conflict_resolution = pya.LoadLayoutOptions.OverwriteCell
    ly.read(g, o)

top = ly.cell(top_name)
if patches:
    names = {"met1": (68, 20), "met2": (69, 20), "met3": (70, 20), "met4": (71, 20), "met5": (72, 20)}
    n = 0
    for line in open(patches):
        f = line.split()
        if not f or f[0] != "PATCH":
            continue
        li = ly.layer(*names[f[1]])
        x1, y1, x2, y2 = (float(v) for v in f[2:6])
        top.shapes(li).insert(pya.DBox(x1, y1, x2, y2))
        n += 1
    print(f"def2gds: {n} patches")

# Cells of the GDS libraries that the design does not use. prune_cell keeps
# subcells used elsewhere (delete_cell_rec does not: some library cells
# contain others, and deleting them took inv_2, nand2_2 and nor2_2 with them).
for c in list(ly.top_cells()):
    if c.name != top_name:
        ly.prune_cell(c.cell_index(), -1)
empty = [ly.cell(ci).name for ci in top.called_cells() if ly.cell(ci).is_empty()]
print(f"def2gds: top {top_name}, {len(list(top.called_cells()))} cells used, empty: {sorted(empty)[:20]}")
ly.write(out)
