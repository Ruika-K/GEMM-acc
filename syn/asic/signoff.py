#!/usr/bin/env python3
"""Sign-off checks of the routed PE macro and chip: GDS, DRC, LVS, antennas.

    python3 syn/asic/signoff.py pe_m4_macro            # the PE macro
    python3 syn/asic/signoff.py chip_8_m4              # the chip (after the PE)
    python3 syn/asic/signoff.py chip_8_m4 --steps drc_klayout lvs
    python3 syn/asic/signoff.py chip_8_m4 --parse      # only re-read the reports

Steps, in order (all by default):

    patches       metal below the minimum area of its layer, left by the
                  router at met2-met3-met4 jogs; patches that keep the
                  spacing (min_area.py)
    gds           GDS from the DEF with KLayout, the cells' own GDS and the
                  patches (def2gds.py); a second GDS for LVS in which the
                  SRAMs keep only their LEF pins (black boxes)
    drc_klayout   the PDK's KLayout rules (sky130A_mr.drc: front and back end,
                  off-grid)
    drc_magic     Magic's full sky130 rules (PE only: on the chip, Magic needs
                  hours)
    lvs           Magic extracts the layout, Netgen compares it with the
                  routed netlist (power pins included) and the standard
                  cells' SPICE netlists
    antenna       OpenROAD's antenna check on the routed database

Tools: Magic >= 8.3.411 (the PDK's tech file needs it), Netgen, KLayout,
OpenROAD; taken from MAGIC, NETGEN, KLAYOUT, OPENROAD or the PATH. Results
in syn/asic/signoff_results.csv, reports in syn/build/asic/<job dir>/signoff/.
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pnr  # noqa: E402

PDK = Path(pnr.PDK_ROOT) / "sky130A"
REF = PDK / "libs.ref" / "sky130_fd_sc_hd"
SRAM = PDK / "libs.ref" / "sky130_sram_macros"
TECH_LEF = REF / "techlef" / "sky130_fd_sc_hd__nom.tlef"
CELL_LEFS = [REF / "lef" / "sky130_fd_sc_hd.lef", REF / "lef" / "sky130_ef_sc_hd.lef"]
SRAM_LEFS = [SRAM / "lef" / f"{m}.lef" for m in pnr.SRAM_MACROS]
SRAM_GDS = [SRAM / "gds" / f"{m}.gds" for m in pnr.SRAM_MACROS]
MAGICRC = PDK / "libs.tech" / "magic" / "sky130A.magicrc"
KLAYOUT_DRC = PDK / "libs.tech" / "klayout" / "drc" / "sky130A_mr.drc"
LAYER_MAP = PDK / "libs.tech" / "klayout" / "tech" / "sky130A.map"
NETGEN_SETUP = PDK / "libs.tech" / "netgen" / "sky130A_setup.tcl"
CELL_SPICE = [REF / "spice" / "sky130_fd_sc_hd.spice", REF / "spice" / "sky130_ef_sc_hd__decap_12.spice"]
RESULTS = HERE / "signoff_results.csv"
STEPS = ["patches", "gds", "drc_klayout", "drc_magic", "lvs", "antenna"]
FIELDS = ["job", "top", "min_area_pieces", "patched", "drc_klayout", "drc_klayout_rules", "drc_magic",
          "drc_magic_rules", "lvs", "lvs_devices", "lvs_nets", "antenna_nets", "antenna_pins"]


def tool(name):
    path = os.environ.get(name.upper()) or shutil.which(name)
    if not path:
        sys.exit(f"{name} not found: set {name.upper()} or put it on the PATH")
    return path


def run(cmd, log, **kw):
    with open(log, "w") as f:
        subprocess.run([str(c) for c in cmd], stdout=f, stderr=subprocess.STDOUT, check=True,
                       env=dict(os.environ, PDK_ROOT=pnr.PDK_ROOT, QT_QPA_PLATFORM="offscreen"), **kw)


class Job:
    def __init__(self, name):
        self.name = name
        self.job = pnr.jobs()[name]
        self.work = pnr.dirs(name, self.job)[1]
        self.top = self.job["top"]
        self.out = self.work / "signoff"
        self.out.mkdir(exist_ok=True)
        self.chip = bool(self.job.get("chip"))
        if self.job.get("hier"):
            mjob = pnr.jobs()[self.job["hier"]]
            self.macro_dir = pnr.dirs(self.job["hier"], mjob)[1]
            self.macro = mjob["top"]
            self.macro_gds = self.macro_dir / "signoff" / f"{self.macro}.gds"
            if not self.macro_gds.exists():
                sys.exit(f"{self.macro_gds} not found: run signoff.py {self.job['hier']} first")
        else:
            self.macro = None

    def f(self, suffix):
        return self.out / f"{self.top}{suffix}"

    def lefs(self):
        out = [TECH_LEF, *CELL_LEFS]
        if self.macro:
            out.append(self.macro_dir / f"{self.macro}.lef")
        if self.chip:
            out += SRAM_LEFS
        return out

    # --------------------------------------------------------------------
    def patches(self):
        macro_lefs = ([self.macro_dir / f"{self.macro}.lef"] if self.macro else []) + (SRAM_LEFS if self.chip else [])
        with open(self.f("_patches.txt"), "w") as fh:
            subprocess.run([sys.executable, HERE / "min_area.py", self.work / f"{self.top}.def", TECH_LEF,
                            "--macro-lef", *macro_lefs], stdout=fh, check=True)

    def power_labels(self):
        """Labels for the power nets of a macro, whose DEF has no pins for
        them: on the first met4 stripe of each (met4 pin layer 71/16, where a
        label is a port to Magic; 71/5 is text only). The
        extraction then names the macro's power ports, and the parent's
        connections to them match the netlist's."""
        text = (self.work / f"{self.top}.def").read_text()
        out = []
        for net in ("VPWR", "VGND"):
            m = re.search(rf"^\s*- {net} .*?ROUTED met4 \d+ \+ SHAPE STRIPE \( (\d+) (\d+) \) \( (?:\*|\d+) (\d+) \)",
                          text, flags=re.M | re.S)
            if m:
                x, y1, y2 = int(m.group(1)) / 1000, int(m.group(2)) / 1000, int(m.group(3)) / 1000
                out.append(f"{net} 71 16 {x:.3f} {(y1 + y2) / 2:.3f}")
        return ";".join(out)

    def gds(self):
        cells = [REF / "gds" / "sky130_fd_sc_hd.gds"] + ([self.macro_gds] if self.macro else [])
        labels = "" if self.chip else self.power_labels()
        for out, extra in ((self.f(".gds"), SRAM_GDS if self.chip else []), (self.f("_lvs.gds"), [])):
            if out.name.endswith("_lvs.gds") and not self.chip:
                continue          # without SRAMs the two are the same
            run([tool("klayout"), "-b", "-r", HERE / "def2gds.py",
                 "-rd", f"def={self.work / (self.top + '.def')}", "-rd", f"out={out}",
                 "-rd", f"map={LAYER_MAP}", "-rd", "lefs=" + " ".join(map(str, self.lefs())),
                 "-rd", "gds=" + " ".join(map(str, cells + extra)),
                 "-rd", f"patches={self.f('_patches.txt')}", "-rd", f"labels={labels}"],
                self.f(f"_{out.stem}.log"))

    def drc_klayout(self):
        run([tool("klayout"), "-b", "-r", KLAYOUT_DRC, "-rd", f"input={self.f('.gds')}", "-rd", f"top_cell={self.top}",
             "-rd", f"report={self.f('_klayout.lyrdb')}", "-rd", "feol=1", "-rd", "beol=1", "-rd", "offgrid=1",
             "-rd", "thr=4"], self.f("_drc_klayout.log"))

    def magic(self, script, log):
        path = self.out / f"{log}.tcl"
        path.write_text(script + "\nquit -noprompt\n")
        run([tool("magic"), "-dnull", "-noconsole", "-rcfile", MAGICRC, path], self.out / f"{log}.log", cwd=self.out)

    def drc_magic(self):
        if self.chip:
            return
        self.magic(f"""gds flatglob *$$*
gds read {self.f('.gds')}
load {self.top}
select top cell
drc euclidean on
drc style drc(full)
drc check
drc catchup
set fh [open {self.f('_magic_drc.txt')} w]
puts $fh "total [drc list count total]"
foreach {{why boxes}} [drc listall why] {{ puts $fh "$why: [llength $boxes]" }}
close $fh""", f"{self.top}_drc_magic")

    def lvs(self):
        gds = self.f("_lvs.gds") if self.chip else self.f(".gds")
        # The SRAMs (LEF pins only in the LVS GDS) are abstract views: kept as
        # black-box subcircuits with their ports. Without this, ext2spice
        # leaves cells without devices out and their nets dangle.
        abstract = "".join(f"load {m}\nproperty LEFview true\n" for m in pnr.SRAM_MACROS) if self.chip else ""
        self.magic(f"""gds flatglob *$$*
gds read {gds}
{abstract}load {self.top}
select top cell
extract no all
extract do local
extract unique
extract all
ext2spice lvs
ext2spice blackbox on
ext2spice -o {self.f('_layout.spice')}""", f"{self.top}_extract")
        # The routed netlist with power pins: cells placed after the power
        # grid (clock tree, repair, fillers) get theirs from global_connect.
        tcl = self.out / "netlist_pwr.tcl"
        reads = "\n".join(f"read_lef {p}" for p in self.lefs())
        # A macro has no pins for its power nets; ports for them, as its LEF
        # and the parent's netlist have.
        ports = ("foreach n {VPWR VGND} {\n"
                 "    set net [[ord::get_db_block] findNet $n]\n"
                 "    if {[[ord::get_db_block] findBTerm $n] eq \"NULL\"} {\n"
                 "        set bt [odb::dbBTerm_create $net $n]\n"
                 "        $bt setIoType INOUT\n"
                 "    }\n}\n") if not self.chip else ""
        tcl.write_text(f"{reads}\nread_db {self.work / (self.top + '.odb')}\nglobal_connect\n{ports}"
                       f"write_verilog -include_pwr_gnd {self.f('_pwr.v')}\n")
        run([tool("openroad"), "-no_init", "-exit", tcl], self.out / "netlist_pwr.log")
        lvs = self.out / "lvs.tcl"
        macro = (f"readnet verilog {self.macro_dir / 'signoff' / (self.macro + '_pwr.v')} $c2\n"
                 if self.macro else "")
        lvs.write_text(f"""set c1 [readnet spice {self.f('_layout.spice')}]
set c2 [readnet verilog {self.f('_pwr.v')}]
{macro}""" + "".join(f"readnet spice {s} $c2\n" for s in CELL_SPICE) +
                       f'lvs "$c1 {self.top}" "$c2 {self.top}" {NETGEN_SETUP} {self.f("_lvs.rpt")}\n')
        run([tool("netgen"), "-batch", "source", lvs], self.out / "lvs.log")

    def antenna(self):
        tcl = self.out / "antenna.tcl"
        reads = "\n".join(f"read_lef {p}" for p in self.lefs())
        tcl.write_text(f"{reads}\nread_db {self.work / (self.top + '.odb')}\n"
                       f"check_antennas -report_file {self.f('_antenna.rpt')}\n")
        run([tool("openroad"), "-no_init", "-exit", tcl], self.out / "antenna.log")

    # --------------------------------------------------------------------
    def parse(self):
        row = dict(job=self.name, top=self.top)
        p = self.f("_patches.txt")
        if p.exists():
            text = p.read_text()
            row["patched"] = len(re.findall(r"^PATCH", text, flags=re.M))
            row["min_area_pieces"] = row["patched"] + len(re.findall(r"^UNFIXED", text, flags=re.M))
        k = self.f("_klayout.lyrdb")
        if k.exists():
            t = k.read_text()
            cats = Counter(re.findall(r"<category>'([^']+)'</category>", t[t.find("<items>"):]))
            row["drc_klayout"] = sum(cats.values())
            row["drc_klayout_rules"] = " ".join(f"{c}:{n}" for c, n in cats.most_common())
        m = self.f("_magic_drc.txt")
        if m.exists():
            lines = m.read_text().splitlines()
            row["drc_magic"] = int(lines[0].split()[1])
            row["drc_magic_rules"] = " ".join(re.sub(r"\s+", "_", l.split(":")[0]) + ":" + l.split(":")[1].strip()
                                              for l in lines[1:])
        r = self.f("_lvs.rpt")
        if r.exists():
            t = r.read_text()
            final = re.findall(r"Final result: (.*)", t)
            row["lvs"] = final[-1].strip().rstrip(".") if final else "no result"
            dev = re.findall(r"Number of devices: (\d+)", t)
            nets = re.findall(r"Number of nets: (\d+)", t)
            row["lvs_devices"] = dev[-2] if len(dev) >= 2 else ""
            row["lvs_nets"] = nets[-2] if len(nets) >= 2 else ""
        a = self.f("_antenna.rpt")
        log = self.out / "antenna.log"
        if log.exists():
            t = log.read_text()
            nets = re.search(r"Found (\d+) net violations", t)
            pins = re.search(r"Found (\d+) pin violations", t)
            row["antenna_nets"] = nets.group(1) if nets else ""
            row["antenna_pins"] = pins.group(1) if pins else ""
        return row


def save(rows):
    old = []
    if RESULTS.exists():
        with open(RESULTS) as f:
            old = list(csv.DictReader(f))
    done = {r["job"] for r in rows}
    with open(RESULTS, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows([r for r in old if r["job"] not in done] + rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("job")
    ap.add_argument("--steps", nargs="*", default=STEPS, choices=STEPS)
    ap.add_argument("--parse", action="store_true")
    args = ap.parse_args()
    job = Job(args.job)
    if not args.parse:
        for step in args.steps:
            print(f"{args.job}: {step}", flush=True)
            getattr(job, step)()
    row = job.parse()
    print(", ".join(f"{k}={v}" for k, v in row.items()))
    save([row])


if __name__ == "__main__":
    main()
