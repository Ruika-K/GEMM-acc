# Synthesis

An ASIC flow (standard cells, SkyWater sky130) and two FPGA flows.

## ASIC: sky130 synthesis, place and route

`asic/run.py` maps the design to `sky130_fd_sc_hd` standard cells with Yosys
and analyses timing with OpenSTA at the typical (tt, 25 C, 1.80 V) and the slow
(ss, 100 C, 1.60 V) corner.

| Job | What is built |
|-----|---------------|
| `mac`, `mac_nopipe`, `mac_ripple` | the multiply-accumulate datapath of a PE (`gemm_mac`) |
| `cpa` | the pipelined adder for saved carries (`gemm_cpa`) |
| `*_sN` | any of the jobs below with a carry saved every N bits of the accumulator (`ACC_SEG = N`, N = 1, 4, 8, 16), mapped for 4 ns instead of 5 ns |
| `*_mN` | the same with the multiplier without a final adder as well (`MUL_CS = 1`, N = 1, 2, 4, 8), mapped for 3 ns; `mac_mN` and `cpa_m` are its datapath and final adder |
| `pe`, `pe_nopipe` | one processing element |
| `sys_N` | `N x N` systolic array |
| `bcast_N` | `N x N` broadcast baseline |
| `sys_8_ripple` | 8 x 8 systolic array with a ripple-carry accumulator adder |
| `sys_8_nopipe` | 8 x 8 systolic array without the product register |
| `core_8` | `gemm_core`: array, skew lines, controller, output FIFO |
| `top_8` | complete accelerator, operand memories as black boxes |

Tools: Yosys 0.40 or newer and OpenSTA (the `sta` binary, also part of
OpenROAD) on `PATH`. With nix:

```bash
nix shell nixpkgs#yosys nixpkgs#openroad
```

PDK: the `common` and `sky130_fd_sc_hd` archives of an open_pdks build,
unpacked so that `$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib` exists.
`PDK_ROOT` defaults to `~/pdk/sky130`.

```bash
python3 syn/asic/run.py
```

Synthesis is bottom-up for `gemm_mac` and `gemm_cpa`: each is mapped once per
variant and that netlist is placed into every design that contains it, so that all arrays,
systolic and broadcast, are built from the same gates.

`core_8*` and `top_8*` are mapped with a different ABC script (`ABC_DELAY`,
job option `abc="delay"`): SOP balancing and delay-oriented resynthesis before
the mapping. With Yosys' default script the counters and comparators of the
control logic came out as ripple chains of OR gates, even though every adder
is first built as a Sklansky prefix tree. The datapath keeps the default
script; it is in the hard modules above.

Results go to `syn/asic/results.csv`; netlists, timing reports and an area
breakdown per module (`breakdown.txt`) to `syn/build/asic/<job>/`. These are
pre-layout numbers: no wires, no clock tree.
The operand memories are SRAM macros in an ASIC and are left out as black
boxes (`asic/gemm_mem_blackbox.sv`).

Gate-level simulation of a synthesised array with the RTL testbench and the
sky130 cell models:

```bash
python3 syn/asic/gls.py sys_8
```

Place and route with OpenROAD, on the netlists the synthesis step left behind:

```bash
python3 syn/asic/pnr.py pe sys_4 bcast_4
python3 syn/asic/pnr.py --parse sys_4      # re-read the log of an earlier run
```

`asic/pnr.tcl` is the flow itself: floorplan, power grid, placement, clock
tree synthesis, setup and hold repair, global and detailed routing, parasitic
extraction, then timing at the typical, slow and fast corner with the extracted
wires. Pins are placed on the side their data flows through (A on the west
edge, B on the north edge, the shift chain south to north). Results go to
`syn/asic/pnr_results.csv`, the layout (DEF, ODB), the SPEF and the log to
`syn/build/asic/<design>/pnr/` (`pnr_est/` for the reduced flow).

| Job | Flow |
|-----|------|
| `pe`, `sys_4`, `bcast_4`, `sys_8`, `bcast_8` | full: timing-driven placement, detailed routing, extracted parasitics |
| `sys_8_est`, `bcast_8_est`, `sys_16_est`, `bcast_16_est` | reduced: placement for wire length, global routing, wire estimates |
| the same names with `_s8` (`sys_8_s8`, `sys_8_s8_est`, ...) | the variant with a carry saved every 8 bits |
| the same names with `_m4` | the variant with the carry-save multiplier and a carry saved every 4 bits |

The 16 x 16 arrays are about 160 000 cells. Timing-driven placement and
detailed routing of a block that size each take hours on a four-core machine,
so they go through the reduced flow, and the 8 x 8 arrays are run through
both to show how the two flows compare. A full 8 x 8 run takes about 50
minutes, a reduced 16 x 16 run about 10. The systolic arrays also go through
the hierarchical flow below, which gives full-flow results for 16 x 16.

Two things in this flow are there because of how OpenROAD (26Q3) behaves when
it cannot close timing:

* Place and route uses its own clock period (`PERIOD` in `pnr.py`, 10 ns; 7 ns
  for the `_s8` and 5 ns for the `_m4` variant), not the period of synthesis. Timing is repaired for all corners at once, and at the
  slow corner 5 ns is out of reach by a factor of two. 10 ns is missed by
  10 - 20 %, so the result is what the tools reach when pushed.
* Setup repair runs with `-skip_buffering`. With buffer insertion enabled it
  left chains of up to 50 single-fanout buffers on paths it could not close,
  and after routing those chains were the critical path. `pnr.py` checks for
  this: `crit_path_bufs` is the number of buffers on the worst path and
  `buf_chain` the longest single-fanout buffer chain in the routed netlist.

Hold is repaired before routing, on wire estimates, with a margin of 0.1 ns
(`HOLD_MARGIN` in `pnr.py`). Without the margin two routed blocks missed hold
by a few picoseconds.

Gate-level simulation of a routed array (clock tree and hold buffers included):

```bash
python3 syn/asic/gls.py --pnr sys_4
python3 syn/asic/gls.py --pnr sys_8_s8
```

### The complete chip

```bash
python3 syn/asic/run.py chip_8_m4                     # synthesis with SRAM macros
python3 syn/asic/pnr.py pe_m4_macro chip_8_m4         # place and route, flat timing
python3 syn/asic/gls.py chip_8_m4                     # gate-level simulation, twice
python3 syn/asic/floorplan_svg.py syn/build/asic/chip_8_m4/pnr/gemm_top.def out.svg <lef files>
```

Needs the `sky130_sram_macros` library next to `sky130_fd_sc_hd` in the PDK
(from the same volare release: `sky130_sram_macros.tar.zst`).

* `chip_8*` synthesis jobs build `gemm_top` with `asic/gemm_mem_sky130.sv` in
  place of the memory black box: A and B from 2 KB macros
  (`sky130_sram_2kbyte_1rw1r_32x512_8`), the bias from 1 KB macros, a
  register in front of each write port and one that holds the read data.
* `pnr_top.tcl` places the PE macros as `pnr_hier.tcl` does and the SRAMs
  around them (A west, B north, bias south), then routes everything. The
  timing models of the SRAMs have one corner, used for all three, and a
  maximum input transition of 0.04 ns that the flow removes from its copies
  (`sram_libs()` in `pnr.py`). `PNR_RESUME=1` (or `route`) starts again from
  the database saved before routing, `PNR_RESUME=cts` from the one saved
  before the clock tree.
* The PEs get a clock tree built by hand (`pe_clock_tree.tcl`): an H-tree
  over the array with its buffers in the channels between the PEs, driven
  from the clock port and lengthened until the flip-flops inside the PEs
  (the macro's own clock tree from its timing model, `max_clock_tree_path`)
  get the clock when the registers around the array do, plus `PE_CLK_LATE`
  in `pnr.py`. OpenROAD's clock tree synthesis builds the trees of the
  registers and of the SRAMs; `sram_clock.tcl` then takes delay buffers out
  of the chain at the root of the SRAM tree until the SRAMs get the clock
  `SRAM_CLK_EARLY` before the registers (their read data has half a cycle).
* The chip is synthesised with `IN_PIPE = 1` (a register stage of its own in
  front of the array, see `docs/spec.md`).
* `sta_flat.tcl` reports the paths through the SRAMs apart from those between
  registers (`sram_slack_ss_ns` in `pnr_results.csv`), and the worst
  difference in clock arrival between neighbouring PEs at the slow corner
  (`macro_skew_ss_ns`, also for the hierarchical arrays). `pnr.py` rejects a
  flat analysis in which parasitics could not be attached to a net.
* `gls.py chip_8_m4` simulates the routed netlist with `tb/test_gemm_top.py`,
  once with every register starting at 0 and once at 1: registers the RTL
  does not reset start at X otherwise, and the netlist, unlike the RTL, keeps
  an X that logic masks. Its copy of the cell library updates the outputs of
  flip-flops like a non-blocking assignment: with zero-delay cells a clock
  tree is a chain of delta cycles, and a register on a shallower tree (the
  PEs: 6 buffers, the other registers: 8 - 10) would otherwise change its
  output before a register on a deeper one samples it.

### Power

```bash
python3 syn/asic/power.py chip_8_m4                 # compute and idle workloads
python3 syn/asic/power.py chip_8_m4 idle --keep-vcd # one workload, keep the VCD file
```

Needs the routed chip (`pnr.py chip_8_m4`). For each workload of
`tb/test_gemm_power.py`, `gls.py` simulates the routed netlist and the chip
wrapper writes a VCD file from the moment the test raises `dump_on` (vvp
needs `-vcd` instead of cocotb's `-none` for that: `IcarusVcd` in `gls.py`).
`power.tcl` reads it with the routed netlists and parasitics as
`sta_flat.tcl` does and reports power at the typical corner: with OpenSTA's
default activity, with the simulated one, per block (PE macros, SRAMs, clock
buffers of the top level), and the duty of the SRAM chip selects, from which
`power.py` works out the SRAM power counted only when selected. Results in
`power_results.csv`, reports in `syn/build/asic/chip_8_m4/pnr/power/`. The
VCD files (hundreds of MB) are deleted after the analysis unless
`--keep-vcd` is given.

### Hierarchical flow

For the 16 x 16 arrays the full flow runs hierarchically: the PE is placed,
routed and extracted once as a hard macro, and the array is built from copies
of it. The top level of an 8 x 8 array takes one to two minutes this way, a
16 x 16 one three to five, and the macro another two, once.

```bash
python3 syn/asic/pnr.py pe_m4_macro                       # the PE as a macro
python3 syn/asic/pnr.py sys_8_m4_hier sys_16_m4_hier      # arrays built from it
python3 syn/asic/gls.py sys_8_m4 --hier                   # gate-level simulation
```

| Job | What it does |
|-----|--------------|
| `pe_macro`, `pe_s8_macro`, `pe_m4_macro` | `pnr.tcl` with `PNR_MACRO=1`, then `etm.tcl`. Output in `syn/build/asic/pe*/macro/` |
| `sys_N_hier`, `sys_N_s8_hier`, `sys_N_m4_hier` (N = 8, 16) | `pnr_hier.tcl`, then `sta_flat.tcl`. Output in `syn/build/asic/sys_N*/pnr_hier/` |

* **The macro** (`pnr.tcl`, `PNR_MACRO=1`). Its pins are placed by hand
  (`PNR_EDGES`, built by `pe_edges()` in `pnr.py`): pin k of the west edge at
  the same height as pin k of the east edge, pin k of the north edge above pin
  k of the south edge, all on routing tracks. Two copies side by side then
  connect with straight wires. The outline is a multiple of the site width
  and of two rows, power and signals stay below met5, and the abstract
  (`gemm_pe.lef`) has every layer up to met4 obstructed as a whole.
* **Its timing models** (`etm.tcl`): one Liberty file per corner, written by
  OpenSTA from the routed netlist and its parasitics, one corner per run.
  With several corners defined, OpenROAD 26Q3 wrote clock-to-output arcs that
  were wrong at the typical and fast corner (1.40 ns where the macro has
  0.52 ns).
* **Budgets.** The path from one PE to the next starts at a register in one
  macro and ends behind the multiplier in the other, so the macro needs to
  know how much of it is outside: inputs may assume 30 % of the period is
  gone (`MACRO_IN`), outputs leave 70 % (`MACRO_OUT`). Hold is a contract:
  outputs stay unchanged for 0.3 ns after the clock edge and inputs tolerate
  a change that early (`MACRO_HOLD`), so the macro repairs hold on its own
  short input paths. The macro is characterised with the slow clock edge it
  gets from the top-level clock tree (`MACRO_CLK_SLEW`).
* **The top level** (`pnr_hier.tcl`): macros on a grid with channels of 30
  sites and 2 rows (`CHANNEL_X`, `CHANNEL_Y`), the final adders in a strip to
  the north, the pins of each row and column next to it, a pair of met4 power
  straps in every vertical channel and met5 straps across the macros. Timing
  repair, clock tree and routing see the macros through their timing models.
* **Sign-off** (`sta_flat.tcl`): flat timing with the routed netlist of the
  top level and of the macro and the extracted parasitics of both, read once
  per macro instance. This is what `pnr_results.csv` reports;
  `fmax_ss_model_mhz` is what the top level saw through the models.
* **Hold from the block inputs is not closed.** The constraints launch the
  inputs at the ideal clock edge while the registers inside see the clock
  after the clock tree, 1 - 2 ns later; repairing that took 3000 delay buffers
  at 16 x 16. It is a property of the constraints, not of the array, and is
  closed when the block sits next to the registers that drive it. The top
  level gets a false path for it; `hold_in_ns` reports it, `hold_slack_ns` is
  hold between registers. (The full flow repairs these paths, which is where
  most of its hold buffers go.)

## FPGA

Two flows that implement the same jobs.

| Job        | What is built |
|------------|---------------|
| `sys_N`    | `N x N` systolic array (`rtl/gemm_array.sv`) inside the harness |
| `bcast_N`  | `N x N` broadcast baseline (`common/gemm_array_bcast.sv`) inside the same harness |
| `*_nopipe` | the same with `PE_PIPE = 0` |
| `*_lut`    | the same with multipliers built from LUTs (ECP5 flow only) |
| `*_dsp`    | the same with DSP blocks forced by `GEMM_USE_DSP` (Vivado flow only) |
| `*_sN`     | the same with a carry saved every N bits of the accumulator, `ACC_SEG = N` |
| `*_mN`     | the same with the multiplier without a final adder as well, `MUL_CS = 1` |
| `top_8`    | the complete accelerator with an 8 x 8 array |

`common/syn_array_harness.sv` feeds all array inputs from a serial register
chain and captures all outputs into another one. An array has far more port
bits than a device has pins; with the harness every array path is register to
register and the wrapper itself is one LUT deep.

`common/gemm_array_bcast.sv` is the comparison point: the same multiply,
product register, accumulator and shift chain per PE, but operands and control are
registered once at the edge and broadcast instead of being forwarded from PE to
PE. It is checked against numpy by `tb/test_gemm_array_bcast.py`.

### Vivado

Status: a `standard` sweep of 17 jobs has been run with Vivado 2023.2 on
xc7z020; the result is in `vivado/results_xc7z020.csv`. The two `_m4` jobs were
added afterwards and have not been run with Vivado. `run.tcl` itself writes
`vivado/results.csv`, which is not tracked.

The `_s8` and `_s1` jobs are there to see what saved carries do on an FPGA.
The fabric has dedicated carry chains, so a 32-bit adder is cheap there, and
the gain seen on the ASIC does not carry over: same frequency, more LUTs.

Vivado builds the 8 x 8 bit multipliers from LUTs by default, so the jobs are
not limited by the number of DSP blocks. The `_dsp` jobs define `GEMM_USE_DSP`,
which puts `(* use_dsp = "yes" *)` on the PE; that costs two DSP blocks per PE.

```bash
vivado -mode batch -source syn/vivado/run.tcl
```

Optional arguments after `-tclargs`: mode (`quick`, `standard`, `full`), part
(default `xc7z020clg400-1`), clock period in ns for the LUT-multiplier jobs
(default `6.0`) and for the DSP jobs (default `3.5`). For example a three-job
smoke test:

```bash
vivado -mode batch -source syn/vivado/run.tcl -tclargs quick
```

Everything is implemented out of context, so only register-to-register paths
are timed. One line per job is written to `syn/vivado/results.csv`; the timing
and utilisation reports are in `syn/build/vivado/<job>/`.

### ECP5 (open source)

Needs `yosys` and `nextpnr-ecp5` from the distribution and a recent Yosys from
PyPI as SystemVerilog front end:

```bash
pip install -r syn/requirements.txt
```

```bash
python3 syn/ecp5/run.py
```

`python3 syn/ecp5/run.py --list` shows the job names; pass names to run a
subset. Results go to `syn/ecp5/results.csv`.
