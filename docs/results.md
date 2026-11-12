# Implementation results

Two kinds of results: an ASIC implementation on an open 130 nm process, which
is the main target, and an FPGA implementation used as a prototype.

| Flow | State |
|------|-------|
| ASIC, sky130, synthesis and pre-layout timing | done |
| ASIC, sky130, place and route of the array | done up to 8 x 8; 16 x 16 to global routing |
| FPGA, Lattice ECP5 (Yosys + nextpnr) | done |
| FPGA, Xilinx (Vivado) | three-job smoke test passed, full sweep pending |

# ASIC: SkyWater sky130, synthesis

Flow: `syn/asic/run.py`, numbers in `syn/asic/results.csv`. Yosys maps the RTL
to the `sky130_fd_sc_hd` standard-cell library, OpenSTA analyses timing.

* Corners: typical (tt, 25 C, 1.80 V) and slow (ss, 100 C, 1.60 V).
* Frequencies are for the worst register-to-register path at a 5 ns
  constraint.
* **These are pre-layout numbers.** No wire delay, no clock tree, no hold
  fixing. The array has been placed and routed, see the next part; the
  complete accelerator has not.
* The operand memories are SRAM macros in an ASIC. They are black boxes here
  and not part of any area figure.
* 1 gate equivalent (GE) = one `nand2_1` = 3.75 um2.
* The multiply-accumulate datapath of the PE (`gemm_mac`) is synthesised once
  and the same netlist is used in every design below, including the broadcast
  baseline. Mapped separately in each design, identical RTL came out up to 7 %
  apart in speed.

## Complete accelerator, 8 x 8 array

`gemm_top` without the memories: **157 kGE** (590 000 um2 of cells), 9739
flip-flops, **161 MHz typical, 80 MHz slow corner**.

Peak throughput is 64 multiply-accumulates per cycle: 5.1 GMAC/s at the slow
corner, 10.3 GMAC/s at the typical one.

Where the area goes (cells of each module type, not counting its submodules):

| Module | Instances | Area (um2) | Share |
|--------|----------:|-----------:|------:|
| `gemm_mac` (PE datapath) | 64 | 368 000 | 62.4 % |
| `gemm_fifo` (output FIFO) | 1 | 92 200 | 15.6 % |
| `gemm_delay` (skew and de-skew) | 41 | 54 500 | 9.2 % |
| `gemm_pe` (PE forwarding registers) | 64 | 25 945 | 4.4 % |
| `gemm_core` (input register, glue) | 1 | 14 900 | 2.5 % |
| `gemm_tile_iter` | 4 | 8 800 | 1.5 % |
| `gemm_load` | 1 | 7 170 | 1.2 % |
| `gemm_csr` | 1 | 7 080 | 1.2 % |
| `gemm_seq` | 1 | 4 514 | 0.8 % |
| `gemm_ctrl` | 1 | 4 160 | 0.7 % |
| `gemm_out` | 1 | 2 410 | 0.4 % |

Three things stand out:

* **The output FIFO is 16 % of the logic.** It holds 8 rows of 257 bits in
  flip-flops. `OUT_DEPTH` is a parameter and the design is correct for any
  depth from 1, so this is a direct area / throughput trade.
* **The skew and de-skew lines are 9 %.** They are 2540 flip-flops, more than
  half as many as the array has, but the array's area is dominated by its
  multipliers and adders.
* **Operand and control forwarding is 4 %**, or 6.6 % of a PE. This is what
  the systolic structure costs in logic area.

Memories that would be SRAM macros: A and B are 1024 x 64 bit each, bias is
64 x 256 bit.

## One processing element

| `PE_PIPE` | Area | Flip-flops | of which datapath (`gemm_mac`) |
|-----------|------|-----------:|--------------------------------|
| 1 | 6157 um2 = 1.6 kGE | 66 | 5752 um2, 48 flip-flops |
| 0 | 6048 um2 = 1.6 kGE | 50 | 5643 um2, 32 flip-flops |

About a quarter of a PE is flip-flops; the rest is the 8 x 8 Booth multiplier,
the 32-bit accumulator adder and the load multiplexer.

## Array size, pipelining and adder architecture

| Design | Area (kGE) | Flip-flops | Fmax typical (MHz) | Fmax slow (MHz) |
|--------|-----------:|-----------:|-------------------:|----------------:|
| systolic 4 x 4 | 26.2 | 1056 | 160 | 84 |
| systolic 8 x 8 | 105.0 | 4224 | 160 | 84 |
| systolic 16 x 16 | 419.9 | 16 896 | 160 | 84 |
| broadcast 4 x 4 | 24.9 | 836 | 160 | 84 |
| broadcast 8 x 8 | 98.8 | 3204 | 159 | 83 |
| broadcast 16 x 16 | 393.8 | 12 548 | 48 | 28 |
| systolic 8 x 8, `PE_PIPE = 0` | 103.1 | 3200 | 139 | 72 |
| systolic 8 x 8, ripple-carry adder | 104.1 | 4224 | 147 | 77 |
| `gemm_core` 8 x 8 | 149.1 | 9299 | 161 | 85 |

* **The accumulate stage is the critical path**, not the multiplier: product
  register -> 32-bit adder -> load multiplexer -> accumulator. The default flow
  therefore maps carry chains to a Sklansky prefix adder, which is 9 % faster
  than ripple carry at both corners for less than 1 % more area.
* **The product register is worth 15 %** at the typical corner (139 -> 160 MHz)
  and 17 % at the slow one, for 2 % more area.
* **Systolic against broadcast.** Before layout the systolic array has the
  same frequency at every size, as it should: every PE is the same netlist and
  there are no wires. The broadcast baseline matches it up to 8 x 8, because
  both are limited by the same path inside the datapath. Its 16 x 16 number is
  not meaningful: logic synthesis does not buffer nets, and here one flip-flop
  drives 16 multipliers and the valid and shift registers drive 256 PEs each.
  Buffering is done during place and route. The baseline is 5 - 6 % smaller.

## Gate-level simulation

`syn/asic/gls.py` runs the array testbench (`tb/test_gemm_array.py`, the one
that checks the RTL) on the synthesised netlists with the functional sky130
cell models. Passing: 4 x 4, 8 x 8, 8 x 8 without product register, 8 x 8 with
ripple-carry adder.

Two things had to be handled that RTL simulation hides: inputs that change on
the clock edge race the clock in a zero-delay netlist, so the netlist is
wrapped and its inputs delayed by 100 ps; and with `PE_PIPE = 0` the array has
a combinational path from `shift_i` to `c_valid_o[0]`, so outputs are sampled
after that delay.

# ASIC: SkyWater sky130, place and route of the array

Flow: `syn/asic/pnr.py` and `syn/asic/pnr.tcl` (OpenROAD), numbers in
`syn/asic/pnr_results.csv`. The synthesised netlist is floorplanned at 50 %
utilisation with pins on the side their data comes from, given a power grid,
placed, given a clock tree, repaired for setup and hold, routed, and timed at
three corners: typical, slow, and fast (ff, -40 C, 1.95 V).

Two flows, because the full one does not scale to the largest array on the
machine used:

* **Full**: timing-driven placement, detailed routing, parasitics extracted
  from the routed layout. One PE, 4 x 4, 8 x 8.
* **Reduced**: placement for wire length, buffering by electrical rules only,
  timing from the wire estimates of global routing. 8 x 8 (for calibration
  against the full flow) and 16 x 16.

Frequencies are for the worst register-to-register path, at a 10 ns target
that the slow corner misses by 10 - 20 %.

## Full flow

| Block | Die (um) | Cell area (um2) | Utilisation | Fmax typical / slow / fast (MHz) | Worst hold slack (ns) | Wire (mm) | DRC |
|-------|----------|----------------:|------------:|----------------------------------|----------------------:|----------:|----:|
| one PE | 122 x 122 | 7 372 | 63 % | 172 / 90 / 275 | 0.38 | 19.7 | 0 |
| systolic 4 x 4 | 455 x 455 | 113 499 | 58 % | 173 / 91 / 276 | 0.21 | 290 | 0 |
| broadcast 4 x 4 | 444 x 444 | 106 791 | 57 % | 172 / 91 / 274 | 0.27 | 294 | 0 |
| systolic 8 x 8 | 899 x 899 | 448 295 | 57 % | 171 / 90 / 274 | 0.21 | 1150 | 0 |
| broadcast 8 x 8 | 872 x 872 | 422 755 | 57 % | 171 / 90 / 274 | 0.27 | 1216 | 0 |

Cell area includes the clock tree, the buffers and the cells that timing
repair made larger, which is why it is above the synthesis figure (4 x 4
systolic: 98 500 -> 113 500 um2). Routed frequencies are above the pre-layout
ones for the same reason: timing repair sizes up the cells on the critical
path by more than the wires cost.

All blocks are free of routing violations and meet hold at every corner; at
these sizes no hold buffers were needed.
The routed 4 x 4 and 8 x 8 systolic arrays pass the array testbench in
gate-level simulation (`syn/asic/gls.py --pnr`), with clock tree, buffers and
resized cells in place. This DRC is the router's own; no sign-off DRC or LVS
has been run.

## Reduced flow

| Block | Die (um) | Cell area (um2) | Fmax typical / slow / fast (MHz) | Buffers added before the clock tree | Cells resized for setup |
|-------|----------|----------------:|----------------------------------|------------------------------------:|------------------------:|
| systolic 8 x 8 | 899 x 899 | 431 448 | 158 / 84 / 250 | 20 | 686 |
| broadcast 8 x 8 | 872 x 872 | 412 792 | 158 / 84 / 250 | 141 | 2832 |
| systolic 16 x 16 | 1787 x 1787 | 1 718 625 | 157 / 83 / 249 | 88 | 1041 |
| broadcast 16 x 16 | 1730 x 1730 | 1 601 000 | 157 / 82 / 246 | 599 | 2572 |

At 8 x 8, where both flows were run, the reduced one is 7 % pessimistic and
treats the two architectures alike. The 16 x 16 arrays needed hold repair: 595
buffers in the systolic array, 711 in the baseline.

## Systolic against broadcast

**Up to 16 x 16 the broadcast baseline is as fast as the systolic array, and
5 - 6 % smaller.** This is not what the systolic structure is usually credited
with, so the reasons are spelled out.

* Both arrays are built from the same datapath netlist, and in both the
  critical path is inside it: product register -> 32-bit adder -> load
  multiplexer -> accumulator. How the operands reach the PE does not enter
  into it.
* The two pipeline stages of the PE are not balanced. Before layout the
  multiply stage (operand register -> multiplier -> product register) takes
  10.3 ns at the slow corner and the accumulate stage 11.5 ns. Broadcast wires
  are in the multiply stage, so the baseline has about 1.2 ns of wire and
  buffer delay to spend before it is slower at all.
* At 16 x 16 that margin is used up. The critical path of the baseline is no
  longer in the accumulator but on a broadcast operand (edge register ->
  buffer -> multiplier -> product register), and the baseline is 1 % slower.
  The systolic array's critical path does not move and its frequency is the
  same at 4 x 4, 8 x 8 and 16 x 16.
* The baseline pays in buffers and wire instead. In the reduced flow the tools
  add several times as many buffers and resize several times as many cells to
  drive the broadcast nets; in the full flow the routed baseline needs 1.5 %
  more wire at 4 x 4 and 5.7 % more at 8 x 8. That is still less area than 18
  forwarding flip-flops per PE.

What the systolic array costs, all told: 6.6 % of the PE area for forwarding,
the skew and de-skew lines around the array (9 % of the complete 8 x 8
accelerator), and the skew itself: operands reach the last PE
`ROWS + COLS - 2` cycles after the first. What it buys at these sizes is a
frequency that does not depend on the array size, and identical PEs with
neighbour-only wiring.

Where the comparison would turn: larger arrays, or a faster accumulate stage.
A carry-save accumulator takes the carry propagation out of that stage; the
multiply stage, which is where the broadcast wires are, would then set the
frequency. Neither has been built, so this is a prediction and not a result.

## Two things the tools did

Both were found by reading the critical path and not only the frequency, and
both would have produced a wrong conclusion.

* **Buffer chains.** With the synthesis target of 5 ns, which the slow corner
  cannot reach, OpenROAD's setup repair left a chain of 50 single-fanout
  buffers on a path of the 8 x 8 baseline. It was the critical path after
  routing and made the baseline look 10 % slower than the systolic array.
  The chain also appeared at reachable targets, in either architecture. The
  flow now repairs setup without buffer insertion, and `pnr.py` checks every
  routed netlist for such chains.
* **Mapping noise.** The same RTL, mapped as part of two different designs,
  gave two different datapath netlists, one 8 % faster after routing. That
  showed up as the baseline being faster at 4 x 4. The datapath is now
  synthesised once (see above).

## Not done yet

* SRAM macros for the operand memories, and timing of the paths through them.
* Place and route of the complete accelerator; only the array has been done.
* The full flow for 16 x 16. The practical way is hierarchical: harden one PE
  as a macro and tile it.
* Sign-off checks: DRC and LVS with the foundry decks, IR drop, antenna.
* Power: OpenSTA's default switching activity is not meaningful for a design
  that idles most of its control logic; it needs activity from simulation.
* Clock gating. Most registers have an enable.
* A faster accumulate stage (carry-save accumulator).

# FPGA prototype: Lattice ECP5

All numbers in this part come from `syn/ecp5/run.py` and are stored in
`syn/ecp5/results.csv`. Device: LFE5UM-85F, speed grade 8, package CABGA756.
Every job is placed and routed with three seeds; frequencies are given as
worst - best seed. The numbers were measured before the PE datapath was moved
into `gemm_mac`; this flow flattens the design, and a re-run of the two 2 x 2
arrays afterwards gave the same resource counts and frequencies within the
spread between seeds. The Vivado flow (`syn/vivado/run.tcl`) has only passed a
three-job smoke test so far; Xilinx numbers will be added after the full sweep.

## Complete accelerator, 8 x 8 array

`gemm_top`, default parameters (`PE_PIPE = 1`, 1024-word A and B memories).

| Metric | Value |
|--------|-------|
| Fmax | 111 - 115 MHz |
| LUT4 | 4124 (7450 logic cells including carry and wide muxes, 9 % of the device) |
| Flip-flops | 8062 |
| 18 x 18 multiplier blocks | 64 (one per PE) |
| 18 kbit block RAM | 16 (A: 4, B: 4, bias: 8) |
| Distributed RAM cells | 65 (output FIFO) |

Throughput at the best seed (114.7 MHz), one multiply-accumulate counted as
two operations:

* peak: 64 MAC per cycle = 7.3 GMAC/s = 14.7 GOP/s
* measured on a 32 x 72 x 32 multiplication (16 full tiles, 1469 cycles in
  simulation): 50.2 MAC per cycle = 5.8 GMAC/s = 11.5 GOP/s

Where the flip-flops go (from a separate synthesis run that keeps the
hierarchy; it totals 8359 because nothing is optimised across module
boundaries):

| Part | Flip-flops |
|------|-----------:|
| 64 PEs (66 each) | 4224 |
| Skew and de-skew delay lines | 2540 |
| Output FIFO | 525 |
| Input register and core glue | 388 |
| Everything else (registers, loader, sequencer, iterators, memories, controller) | about 700 |

The delay lines are 60 % as large as the array itself. ECP5 has no
shift-register LUT primitive, so every stage is a flip-flop here. On Xilinx
devices the data lines are written to map onto SRLs; whether they do is one of
the things the Vivado run has to show.

The critical path of the complete design is not in the array. It runs from the
tile iterator of the result serialiser through the row-end comparison to the
read pointer of the output FIFO. An earlier critical path, from the AXI4-Lite
write logic through the request checks into the sequencer, was removed by
registering the request pulses.

## Systolic array against the broadcast baseline

`sys_N` is the `N x N` systolic array, `bcast_N` the baseline of
`syn/common/gemm_array_bcast.sv`: the same multiplier, product register and
accumulator per PE, but operands and control registered once at the edge and
broadcast. Both sit in the same serial harness.

Fmax in MHz, worst - best of three seeds:

| N  | Multiplier | systolic  | broadcast |
|----|------------|-----------|-----------|
| 2  | block      | 181 - 183 | 173 - 180 |
| 4  | block      | 139 - 156 | 157 - 159 |
| 8  | block      | 107 - 122 | 125 - 130 |
| 12 | block      |  84 - 93  |  90 - 111 |
| 4  | LUT        | 142 - 143 | 139 - 141 |
| 8  | LUT        | 116 - 122 | 118 - 120 |
| 12 | LUT        |  99 - 104 |  97 - 108 |

**On this device and with this flow the systolic array is not faster than the
baseline.** With block multipliers it is equal or slower; with LUT multipliers
the two are indistinguishable. Both lose frequency as the array grows.

What the timing reports show:

* Routing is about 60 - 70 % of the critical paths of the 8 x 8 and 12 x 12
  arrays, and the path is register -> multiplier -> product register.
* ECP5 multiplier blocks exist only in a few fixed rows. A PE's registers and
  its multiplier end up tens of tiles apart whichever way the operands arrive,
  so the neighbour-only wiring of the systolic array buys nothing.
* With LUT multipliers the PEs could be placed as a mesh, but the placer does
  not do so: the critical net of the 12 x 12 systolic array connects two
  neighbouring PEs that were placed 58 columns apart. Architectural locality
  does not become physical locality by itself.
* The seed-to-seed spread (about 20 % for the 12 x 12 baseline) is as large as
  the differences between the two architectures.

What this does and does not establish: up to 12 x 12, on ECP5, with an
unguided open-source placer, broadcast fan-out of 12 is not the limiting
factor. It says nothing yet about larger arrays, about devices with a dense
grid of DSP blocks that have internal pipeline registers, or about a
floorplanned placement.

Area: the systolic array needs slightly more of everything (12 x 12: 8053
against 7901 flip-flops, 5304 against 5009 LUT4), because every PE forwards its
operands and control.

## Product register

8 x 8 systolic array, block multipliers:

| `PE_PIPE` | Fmax (MHz) | Flip-flops |
|-----------|------------|-----------:|
| 0         | 77 - 84    | 2768 |
| 1         | 107 - 122  | 3801 |

The register between multiplier and adder raises Fmax by about 40 - 45 % for
1033 flip-flops (about 16 per PE). Yosys does not pack it into the multiplier block's own
output register, so on ECP5 it is built from fabric flip-flops and the path
still leaves the block; a vendor flow that uses the block's internal registers
should gain more.

## Reproducing

See [syn/README.md](../syn/README.md).
