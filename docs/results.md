# Implementation results

Two kinds of results: an ASIC implementation on an open 130 nm process, which
is the main target, and an FPGA implementation used as a prototype.

| Flow | State |
|------|-------|
| ASIC, sky130, synthesis and pre-layout timing | done |
| ASIC, sky130, place and route of the array | done up to 8 x 8; 16 x 16 to global routing |
| FPGA, Lattice ECP5 (Yosys + nextpnr) | done |
| FPGA, Xilinx Zynq-7000 (Vivado) | done |

The short version, 8 x 8 array on sky130, slow corner:

| | Plain | Carry saved every 8 bits (`ACC_SEG = 8`) | No carry chain in the PE (`MUL_CS = 1`, `ACC_SEG = 4`) |
|---|---|---|---|
| Array, placed and routed | 89 MHz, 0.81 mm2 | 121 MHz, 0.88 mm2 | **198 MHz**, 1.01 mm2 |
| Complete accelerator, synthesis only, without memories | 86 MHz, 157 kGE | 107 MHz, 166 kGE | 125 MHz, 184 kGE |

Systolic against broadcast, same datapath in both, three technologies:

| | systolic | broadcast |
|---|---|---|
| ECP5, LUT multipliers, 4 x 4 -> 12 x 12 | about 150 MHz throughout | 138 -> 99 MHz |
| Zynq-7000, 4 x 4 -> 16 x 16 | 164 -> 158 MHz | 156 -> 139 MHz |
| sky130, routed, slow corner, 4 x 4 -> 8 x 8, plain accumulator | 90 -> 89 MHz | 90 -> 90 MHz |
| sky130, routed, slow corner, 4 x 4 -> 8 x 8, `ACC_SEG = 8` | 122 -> 121 MHz | 118 -> 115 MHz |
| sky130, routed, slow corner, 4 x 4 -> 8 x 8, `MUL_CS = 1` | 194 -> 198 MHz | 182 -> 165 MHz |

The more of the critical path is wire, the more the neighbour-only wiring is
worth. On the FPGAs routing is over half of it; on the ASIC the difference
only appears once the accumulator adder no longer hides it.

# ASIC: SkyWater sky130, synthesis

Flow: `syn/asic/run.py`, numbers in `syn/asic/results.csv`. Yosys maps the RTL
to the `sky130_fd_sc_hd` standard-cell library, OpenSTA analyses timing.

* Corners: typical (tt, 25 C, 1.80 V) and slow (ss, 100 C, 1.60 V).
* Frequencies are for the worst register-to-register path. The logic is mapped
  for a 5 ns clock, the variants with saved carries for 4 ns, those with the
  carry-save multiplier for 3 ns.
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

`gemm_top` without the memories:

| | Area | Flip-flops | Fmax typical / slow |
|---|---|---:|---|
| default parameters | 157 kGE (590 000 um2) | 9747 | 164 / 86 MHz |
| `ACC_SEG = 8` | 166 kGE | 10 607 | 227 / 107 MHz |
| `MUL_CS = 1`, `ACC_SEG = 4` | 184 kGE | 12 371 | 257 / 125 MHz |

The two options are explained below. Peak throughput is 64
multiply-accumulates per cycle: 5.5, 6.8 and 8.0 GMAC/s at the slow corner.

Where the area goes (default parameters; cells of each module type, not
counting its submodules):

| Module | Instances | Area (um2) | Share |
|--------|----------:|-----------:|------:|
| `gemm_mac` (PE datapath) | 64 | 369 280 | 62.5 % |
| `gemm_fifo` (output FIFO) | 1 | 92 200 | 15.6 % |
| `gemm_delay` (skew and de-skew) | 41 | 54 500 | 9.2 % |
| `gemm_pe` (PE forwarding registers) | 64 | 25 945 | 4.4 % |
| `gemm_core` (input register, glue) | 1 | 14 900 | 2.5 % |
| `gemm_tile_iter` | 4 | 8 640 | 1.5 % |
| `gemm_load` | 1 | 7 180 | 1.2 % |
| `gemm_csr` | 1 | 7 080 | 1.2 % |
| `gemm_seq` | 1 | 4 550 | 0.8 % |
| `gemm_ctrl` | 1 | 4 130 | 0.7 % |
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
| 1 | 6173 um2 = 1.6 kGE | 66 | 5768 um2, 48 flip-flops |
| 0 | 6048 um2 = 1.6 kGE | 50 | 5643 um2, 32 flip-flops |

About a quarter of a PE is flip-flops; the rest is the 8 x 8 Booth multiplier,
the 32-bit accumulator adder and the load multiplexer.

## Array size, pipelining and adder architecture

Plain accumulator (`ACC_SEG = 0`):

| Design | Area (kGE) | Flip-flops | Fmax typical (MHz) | Fmax slow (MHz) |
|--------|-----------:|-----------:|-------------------:|----------------:|
| systolic 4 x 4 | 26.3 | 1056 | 163 | 85 |
| systolic 8 x 8 | 105.3 | 4224 | 163 | 85 |
| systolic 16 x 16 | 421.0 | 16 896 | 163 | 85 |
| broadcast 4 x 4 | 25.0 | 836 | 163 | 85 |
| broadcast 8 x 8 | 99.1 | 3204 | 161 | 84 |
| broadcast 16 x 16 | 394.9 | 12 548 | 48 | 27 |
| systolic 8 x 8, `PE_PIPE = 0` | 103.1 | 3200 | 139 | 72 |
| systolic 8 x 8, ripple-carry adder | 103.6 | 4224 | 146 | 75 |
| `gemm_core` 8 x 8 | 149.4 | 9299 | 164 | 86 |

* **The accumulate stage is the critical path**, not the multiplier: product
  register -> 32-bit adder -> load multiplexer -> accumulator. The default flow
  therefore maps carry chains to a Sklansky prefix adder, which is 12 % faster
  than ripple carry for 2 % more area.
* **The product register is worth 17 %** (139 -> 163 MHz typical, 72 -> 85 MHz
  slow), for 2 % more area.
* **Systolic against broadcast.** Before layout the systolic array has the
  same frequency at every size, as it should: every PE is the same netlist and
  there are no wires. The broadcast baseline matches it up to 8 x 8, because
  both are limited by the same path inside the datapath. Its 16 x 16 number is
  not meaningful: logic synthesis does not buffer nets, and here one flip-flop
  drives 16 multipliers and the valid and shift registers drive 256 PEs each.
  Buffering is done during place and route. The baseline is 5 - 6 % smaller.

## Saved carries in the accumulator

Since the accumulate stage limits the clock, the next step is to take the
carry propagation out of it. `ACC_SEG = n` cuts the 32-bit adder into n-bit
segments. The carry out of a segment is not passed to the next segment in the
same cycle; it is saved in a flip-flop and added there one cycle later. The
accumulated value is then the stored sum plus a few saved carries. They travel
along the shift chain with the sum and are added in once, by a pipelined adder
per column at the north edge of the array (`gemm_cpa`). `ACC_SEG = 1` is the
textbook carry-save accumulator: one full adder per bit and a saved carry per
bit.

| `ACC_SEG` | Datapath (um2) | Flip-flops per PE | Accumulate stage alone, typical / slow (MHz) | 8 x 8 array (kGE) | 8 x 8 array, typical / slow (MHz) |
|-----------|---------------:|------------------:|----------------------------------------------|------------------:|-----------------------------------|
| 0 (plain) | 5768 | 66 | 163 / 85 | 105.3 | 163 / 85 |
| 16 | 5826 | 67 | 242 / 123 | 113.6 | 227 / 118 |
| 8 | 5858 | 69 | 285 / 143 | 114.1 | 227 / 118 |
| 4 | 6091 | 73 | 374 / 192 | 118.1 | 227 / 118 |
| 1 (carry-save) | 6848 | 97 | 493 / 252 | 131.0 | 227 / 118 |

* **One saved carry is enough.** With any setting the array runs at 227 / 118
  MHz, because the multiply stage (operand register -> multiplier -> product
  register) is then the critical path. Cutting the adder further only adds
  flip-flops: the full carry-save form costs 19 % more datapath area for no
  gain.
* **The default for the faster variant is `ACC_SEG = 8`.** It leaves the
  accumulate stage 20 % faster than the multiply stage, for three flip-flops
  per PE (1.6 % of the datapath).
* **What it costs.** The 8 x 8 array grows by 8 %: 1.6 % in the PEs and the
  rest in the eight final adders, which are generic 32-bit adders in two
  pipeline stages (3311 um2 each). Their share halves with every doubling of
  the array (16 x 16: + 5 %). Results leave the array two cycles later; the
  tile period is unchanged.
* **Frequency: + 39 %** before layout, for the array.

## A multiplier without a final adder

With the accumulator out of the way the multiply stage is the critical path,
and a multiplier ends in a carry-propagate adder too: the partial products
are reduced to two rows by a tree of 3:2 compressors, and the two rows are
added. `MUL_CS = 1` selects a datapath (`gemm_mac_cs`) that leaves that
addition out. The two rows are registered as they are and merged with the
accumulator by one more layer of full adders in the accumulate stage; what is
left to add there is two rows again, and that goes through the segmented
adder with saved carries. A PE then has no carry chain longer than `ACC_SEG`
bits.

The multiplier is written out for this: Baugh-Wooley partial products (the
terms with exactly one sign bit inverted, a constant to make up for it), four
levels of 3:2 compressors for 8 x 8 bits, and a correction of the top bit of
the two rows that gives them the right sign extension without knowing the
sign of their sum.

8 x 8 systolic array:

| `MUL_CS` | `ACC_SEG` | Flip-flops per PE | Datapath (um2) | Accumulate stage alone, slow (MHz) | Array (kGE) | Array, typical / slow (MHz) |
|----------|-----------|------------------:|---------------:|-----------------------------------:|------------:|-----------------------------|
| 0 | 0 | 66 | 5768 | 85 | 105.3 | 163 / 85 |
| 0 | 8 | 69 | 5858 | 143 | 114.1 | 227 / 118 |
| 1 | 8 | 80 | 6451 | 158 | 128.6 | 349 / 161 |
| 1 | 4 | 84 | 6659 | 179 | 132.2 | 340 / 162 |
| 1 | 2 | 92 | 6990 | 210 | 137.8 | 346 / 159 |
| 1 | 1 | 108 | 7493 | 203 | 146.4 | 367 / 176 |

* **The multiply stage drops from 8.5 to 5.9 ns** at the slow corner, and the
  array from 118 to 162 MHz. Against the plain design that is 1.9 times the
  frequency for 1.26 times the area.
* **`ACC_SEG = 4` is used with it.** The accumulate stage has an extra layer
  of full adders now, so 8-bit segments leave it level with the multiply
  stage; 4-bit segments leave 10 % of margin.
* **The final adders had to follow.** After routing, the critical path of the
  systolic array was in the adders at the north edge, which added 16 bits per
  cycle. They add 8 bits per cycle in this variant (`CPA_SEG = 8`), and
  results leave the array four cycles after the shift instead of two.
* **Cost per PE**: 18 more flip-flops than the plain PE (the second row of
  the product, the saved carries) and 15 % more datapath area.

## The control logic around the array

Every time the array became faster, the complete accelerator stopped at a
path outside it. Slow corner, before layout:

| | Array | Complete accelerator | What limits the accelerator |
|---|---|---|---|
| plain, first version | 85 MHz | 80 MHz | tile iterator: comparators on the remaining counts |
| plain | 85 MHz | 86 MHz | the array |
| `ACC_SEG = 8` | 118 MHz | 107 MHz | tile controller |
| `MUL_CS = 1`, `ACC_SEG = 4` | 162 MHz | 125 MHz | 16-bit counter of the loader |

What was changed on the way: counters that compared against a dimension
register minus one count down from the dimension to one; the tile iterator
keeps its "last tile" conditions as flags, set when the counts change,
instead of recomputing them with comparators; the logic is mapped for the
clock the datapath can reach, since technology mapping stops improving a
path once it meets the target. What is left are plain 16-bit down counters,
which the mapper builds as ripple chains.

## Gate-level simulation

`syn/asic/gls.py` runs the array testbench (`tb/test_gemm_array.py`, the one
that checks the RTL) on the synthesised netlists with the functional sky130
cell models. Passing: 4 x 4 and 8 x 8, plain, with `ACC_SEG = 8` and with
`MUL_CS = 1`, `ACC_SEG = 4`; 4 x 4 with `ACC_SEG = 1` and `16`; 8 x 8 without
product register and with the ripple-carry adder.

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

Three variants of the datapath: plain, `ACC_SEG = 8`, and `MUL_CS = 1` with
`ACC_SEG = 4`. Frequencies are for the worst register-to-register path. The
clock target is one the slow corner misses: 10, 7 and 5 ns for the three
variants. Hold is repaired with a margin of 0.1 ns.

## Full flow

| Block | Die (um) | Cell area (um2) | Fmax typical / slow / fast (MHz) | Worst hold slack (ns) | Wire (mm) | DRC |
|-------|----------|----------------:|----------------------------------|----------------------:|----------:|----:|
| **plain** | | | | | | |
| systolic 4 x 4 | 456 x 456 | 113 377 | 171 / 90 / 273 | 0.22 | 290 | 0 |
| broadcast 4 x 4 | 444 x 444 | 106 580 | 171 / 90 / 273 | 0.28 | 291 | 0 |
| systolic 8 x 8 | 900 x 900 | 446 979 | 169 / 89 / 270 | 0.21 | 1144 | 0 |
| broadcast 8 x 8 | 874 x 874 | 422 788 | 170 / 90 / 272 | 0.28 | 1204 | 0 |
| **`ACC_SEG = 8`** | | | | | | |
| systolic 4 x 4 | 488 x 488 | 130 620 | 228 / 122 / 357 | 0.20 | 315 | 0 |
| broadcast 4 x 4 | 478 x 478 | 126 297 | 222 / 118 / 351 | 0.20 | 320 | 0 |
| systolic 8 x 8 | 937 x 937 | 496 041 | 227 / 121 / 357 | 0.10 | 1283 | 0 |
| broadcast 8 x 8 | 911 x 911 | 472 638 | 219 / 115 / 342 | 0.10 | 1277 | 0 |
| **`MUL_CS = 1`, `ACC_SEG = 4`** | | | | | | |
| systolic 4 x 4 | 531 x 531 | 158 658 | 392 / 194 / 633 | 0.11 | 379 | 0 |
| broadcast 4 x 4 | 521 x 521 | 157 721 | 366 / 182 / 587 | 0.11 | 386 | 0 |
| systolic 8 x 8 | 1007 x 1007 | 570 323 | **392 / 198 / 620** | 0.13 | 1469 | 0 |
| broadcast 8 x 8 | 984 x 984 | 553 396 | 326 / 165 / 519 | 0.12 | 1556 | 0 |

One plain PE on its own is 122 x 122 um.

**The routed 8 x 8 systolic array, from the plain datapath to the one without
carry chains: 169 / 89 MHz -> 227 / 121 MHz -> 392 / 198 MHz, on 0.81 -> 0.88
-> 1.01 mm2.** That is 2.2 times the frequency at the slow corner for 1.25
times the die area.

Cell area includes the clock tree, the buffers and the cells that timing
repair made larger, which is why it is above the synthesis figure. Routed
frequencies are above the pre-layout ones for the same reason: timing repair
sizes up the cells on the critical path by more than the wires cost.

All blocks are free of routing violations and meet hold at every corner. The
routed 4 x 4 and 8 x 8 systolic arrays of all three variants pass the array
testbench in gate-level simulation (`syn/asic/gls.py --pnr`), with clock
tree, buffers and resized cells in place. This DRC is the router's own; no
sign-off DRC or LVS has been run.

Hold needs more attention as the datapath gets faster and the shift chain
wider. The plain arrays needed no hold buffers, the 8 x 8 systolic array with
`ACC_SEG = 8` has 149, and the one with `MUL_CS = 1` has 754, and the worst hold slack is at the slow corner,
not the fast one: the clock tree and its skew scale with the corner too. A
first run of this variant without the margin missed hold on two blocks, by 2
and 19 ps, after routing had moved the wire delays away from the estimates
that hold repair had worked on.

## Reduced flow

Fmax typical / slow (MHz):

| Block | Plain | `ACC_SEG = 8` | `MUL_CS = 1`, `ACC_SEG = 4` |
|-------|-------|----------------|------------------------------|
| systolic 8 x 8 | 158 / 83 | 217 / 115 | 369 / 183 |
| broadcast 8 x 8 | 157 / 83 | 195 / 103 | 286 / 149 |
| systolic 16 x 16 | 156 / 82 | 215 / 114 | 343 / 174 |
| broadcast 16 x 16 | 153 / 78 | 170 / 91 | 241 / 129 |

How far to trust this flow: at 8 x 8, where both flows were run, it is 5 - 8 %
pessimistic for the systolic array and 8 - 10 % for the baseline, so it
overstates the gap between the two by a few per cent: the broadcast nets need
buffering that follows timing, and this flow only buffers for electrical
rules. The 16 x 16 baseline numbers are the softest in this document.

## Systolic against broadcast

Both arrays are built from the same datapath netlist; what differs is how
operands and control reach the PEs. Slow-corner frequency of the baseline
relative to the systolic array:

| Size | Flow | Plain | `ACC_SEG = 8` | `MUL_CS = 1`, `ACC_SEG = 4` |
|------|------|-------|----------------|------------------------------|
| 4 x 4 | full | equal | - 3 % | - 6 % |
| 8 x 8 | full | equal (+ 1 %) | - 5 % | - 17 % |
| 8 x 8 | reduced | equal | - 10 % | - 19 % |
| 16 x 16 | reduced | - 5 % | - 20 % | - 26 % |

Read along a row, the table says: the shorter the logic in the PE, the more
the broadcast wires cost. Read down a column: the larger the array, the more
they cost.

**With the plain accumulator the two are equally fast up to 8 x 8**, and the
baseline is 5 - 6 % smaller.

* In both, the critical path is inside the datapath: product register ->
  32-bit adder -> load multiplexer -> accumulator. How the operands reach the
  PE does not enter into it.
* The two pipeline stages of the PE are not balanced. Before layout the
  multiply stage takes about 10 ns at the slow corner and the accumulate stage
  11.5 ns. Broadcast wires are in the multiply stage, so the baseline has more
  than a nanosecond of wire and buffer delay to spend before it is slower at
  all. At 16 x 16 that margin is used up.
* The baseline pays in wire and buffers instead: routed, it needs 5 % more
  wire at 8 x 8, and in the reduced flow several times as many buffers.

**Once the carry chains are out of the PE, the multiply stage is the critical
path of both, and the baseline falls behind as the array grows.**

* Systolic: forwarding register of the neighbouring PE -> partial products
  and compressor tree -> row registers. The path is the same in every PE of
  every array, and with `MUL_CS = 1` the routed frequency is 194 MHz at 4 x 4
  and 198 MHz at 8 x 8.
* Baseline: edge register -> buffers and wire across the array -> the same
  logic. 182 MHz at 4 x 4, 165 MHz at 8 x 8.
* The systolic array misses its 5 ns target by 1 % at 8 x 8, the baseline by
  21 %. The baseline is the smaller of the two by 5 % in die area and 3 % in
  cells, and needs 6 % more wire.

The comparison only shows a difference once the pipeline is balanced. In the
plain design the adder hid it. The FPGA results below say the same thing from
the other side: there routing is more than half of every path from the start,
and the systolic array is ahead from the start.

What the systolic array costs, all told: 6.6 % of the plain PE area for
forwarding, the skew and de-skew lines around the array (9 % of the complete
8 x 8 accelerator), and the skew itself: operands reach the last PE
`ROWS + COLS - 2` cycles after the first.

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
* The control logic of the complete accelerator, which limits it to 125 MHz
  at the slow corner before layout while the array reaches 162 MHz.
* A final adder sized for the carries it actually gets: with `ACC_SEG = 4`
  seven of its 32 carry inputs can be non-zero.
* Booth recoding of the multiplier, which would halve the number of partial
  product rows.
* Sign-off checks: DRC and LVS with the foundry decks, IR drop, antenna.
* Power: OpenSTA's default switching activity is not meaningful for a design
  that idles most of its control logic; it needs activity from simulation.
* Clock gating. Most registers have an enable.

# FPGA prototype: Xilinx Zynq-7000 (Vivado)

Flow: `syn/vivado/run.tcl`, Vivado 2023.2, device xc7z020clg400-1,
out-of-context synthesis and implementation at a 6 ns clock target. Numbers
in `syn/vivado/results_xc7z020.csv`.

## Complete accelerator, 8 x 8 array

| | Plain accumulator | `ACC_SEG = 8` |
|---|---|---|
| Fmax | 162.7 MHz | 162.2 MHz |
| LUTs | 7238 | 8448 |
| of which shift-register LUTs | 218 | 230 |
| of which LUT RAM (output FIFO) | 172 | 172 |
| Flip-flops | 5641 | 6208 |
| Block RAM tiles | 8 | 8 |
| DSP blocks | 0 | 0 |

Peak throughput: 64 multiply-accumulates per cycle = 10.4 GMAC/s.

* **The multipliers are LUTs, not DSP blocks.** Vivado builds an 8 x 8 bit
  multiplier from LUTs and carry chains by default. A whole PE is about 93
  LUTs, and the array is 5979 of the 7238 LUTs. Forcing DSP blocks costs two per PE (128 for the
  8 x 8 array, more than half of the device's 220), one for the multiplier and
  one for the accumulator.
* **The skew lines become shift-register LUTs.** The 30 delay lines take 218
  SRLs and 756 flip-flops; on the ECP5, which has no such primitive, the same
  lines are 2540 flip-flops. This is what leaving the reset off the data delay
  lines was for.
* **The critical path is the multiply stage**: forwarding register of the
  neighbouring PE -> LUT multiplier -> product register, seven logic levels,
  53 % of the delay in routing. All five worst paths end at a product
  register.
* **Saved carries buy nothing here.** With `ACC_SEG = 8` the frequency is the
  same and the design is 17 % larger in LUTs (the array alone: 19 %, and 33 %
  for the full carry-save form). The accumulator was never the
  critical path on this device: the fabric has dedicated carry chains, and a
  32-bit addition on them is faster than a multiplier built from LUTs. The
  same change is worth 36 % on the ASIC, where the adder has to be built from
  gates. An optimisation of the arithmetic belongs to a technology, not to the
  RTL.

## Systolic array against the broadcast baseline

Both arrays inside `syn/common/syn_array_harness.sv`, LUT multipliers, one
implementation run each:

| N | systolic (MHz) | broadcast (MHz) | LUTs, systolic / broadcast | Flip-flops, systolic / broadcast |
|---|---------------:|----------------:|----------------------------|----------------------------------|
| 4 | 164.2 | 156.0 | 1692 / 1695 | 1322 / 1273 |
| 8 | 163.3 | 152.8 | 6420 / 6351 | 4724 / 4228 |
| 12 | 162.2 | 142.1 | 14 450 / 14 104 | 10 263 / 8500 |
| 16 | 157.8 | 138.8 | 25 431 / 24 808 | 17 877 / 14 469 |

**The systolic array loses 4 % from 4 x 4 to 16 x 16, the baseline 11 %**, and
the systolic array is 5 % ahead at 4 x 4 and 14 % ahead at 16 x 16.

* Systolic, 8 x 8: the worst path starts at the forwarding register of the
  neighbouring PE, on a net with 20 loads. Baseline: it starts at an edge
  register, on a net with 128 loads spread over a column of the array, and
  routing is 59 % of the path against 53 %. The logic is the same seven
  levels in both.
* The LUT counts are within 3 % of each other; the systolic array has 4 %
  more flip-flops at 4 x 4 and 24 % more at 16 x 16.
* The harness keeps the array intact: interior PEs have 17 of their 18
  forwarding flip-flops (the shift control, which is the same in every row of
  a column, is shared), PEs on the east and south edge lose the registers
  that drive nothing.

Variants of the 8 x 8 arrays:

| Variant | systolic (MHz) | broadcast (MHz) | Note |
|---------|---------------:|----------------:|------|
| default | 163.3 | 152.8 | |
| `PE_PIPE = 0` | 117.5 | 111.9 | the product register is worth 39 % |
| DSP blocks forced, 3.5 ns target | 258.2 | 199.5 | 128 DSP blocks; with the logic this fast the wires decide, and the systolic array is 29 % ahead |
| `ACC_SEG = 8` | 163.5 | 151.8 | 19 % more LUTs, no gain |
| `ACC_SEG = 1` | 164.0 | | 33 % more LUTs, no gain |

An earlier run of this sweep is not used. Its harness fed the array from a
plain serial shift register, and in a shift register bit n + 1 is bit n one
cycle later, which is exactly what the forwarding register of a PE is.
Vivado merged the two: a PE kept 5.5 of its 18 forwarding flip-flops on
average, the worst path of the "systolic" array ran from a register named
after row 6 to a multiplier in row 3, and the two architectures came out
equal at every size. Yosys did the same in the ECP5 flow. The harness now
XORs every bit of its chain with a bit from the other half, so that none of
its registers has the same input as a register of the array. The complete
accelerator was never affected (it does not use the harness), and neither was
the ASIC flow (the arrays are synthesised on their own, with the PE hierarchy
kept).

# FPGA prototype: Lattice ECP5

All numbers in this part come from `syn/ecp5/run.py` (Yosys + nextpnr) and are
stored in `syn/ecp5/results.csv`. Device: LFE5UM-85F, speed grade 8, package
CABGA756. Every job is placed and routed with three seeds; frequencies are
given as worst - best seed.

## Complete accelerator, 8 x 8 array

`gemm_top`, default parameters (`PE_PIPE = 1`, 1024-word A and B memories).

| Metric | Value |
|--------|-------|
| Fmax | 132 - 138 MHz |
| LUT4 | 4164 |
| Flip-flops | 8070 |
| 18 x 18 multiplier blocks | 64 (one per PE) |
| 18 kbit block RAM | 16 (A: 4, B: 4, bias: 8) |
| Distributed RAM cells | 65 (output FIFO) |

Throughput at the best seed (137.9 MHz), one multiply-accumulate counted as
two operations:

* peak: 64 MAC per cycle = 8.8 GMAC/s = 17.7 GOP/s
* measured on a 32 x 72 x 32 multiplication (16 full tiles, 1469 cycles in
  simulation): 50.2 MAC per cycle = 6.9 GMAC/s = 13.8 GOP/s

Where the flip-flops go (from a separate synthesis run that keeps the
hierarchy; it totals more than the flat design because nothing is optimised
across module boundaries):

| Part | Flip-flops |
|------|-----------:|
| 64 PEs (66 each) | 4224 |
| Skew and de-skew delay lines | 2540 |
| Output FIFO | 525 |
| Input register and core glue | 388 |
| Everything else (registers, loader, sequencer, iterators, memories, controller) | about 700 |

The delay lines are 60 % as large as the array itself. ECP5 has no
shift-register LUT primitive, so every stage is a flip-flop here; on the Zynq
the same lines are 218 SRLs and 756 flip-flops.

The critical path of the complete design is in the control logic, between
the tile controller and the bias stream of the sequencer, and three quarters
of it is routing. Two earlier critical paths are gone: one from the AXI4-Lite
write logic through the request checks into the sequencer (removed by
registering the request pulses) and the comparators of the tile iterators
(replaced by flags, see the ASIC part); together they took the design from
105 - 112 MHz to the present figure.

## Systolic array against the broadcast baseline

`sys_N` is the `N x N` systolic array, `bcast_N` the baseline of
`syn/common/gemm_array_bcast.sv`: the same datapath per PE, but operands and
control registered once at the edge and broadcast. Both sit in the same
harness. An earlier version of this table showed no difference between the
two; that was the register merging described at the end of the Xilinx part,
and those numbers are withdrawn.

Fmax in MHz, worst - best of three seeds:

| N  | Multiplier | systolic  | broadcast | Flip-flops, systolic / broadcast |
|----|------------|-----------|-----------|----------------------------------|
| 2  | block      | 179 - 184 | 178 - 182 | 395 / 393 |
| 4  | block      | 154 - 172 | 155 - 159 | 1309 / 1165 |
| 8  | block      | 107 - 146 | 103 - 131 | 4697 / 3861 |
| 12 | block      | 114 - 133 | 90 - 98   | 10 165 / 8093 |
| 4  | LUT        | 145 - 159 | 136 - 140 | 1309 / 1165 |
| 8  | LUT        | 146 - 152 | 114 - 120 | 4697 / 3861 |
| 12 | LUT        | 143 - 148 | 99 - 100  | 10 165 / 8093 |

**The systolic array keeps its frequency as it grows and the baseline does
not.** With multipliers built from LUTs, where the placer is free to put a
PE's logic together, the systolic array runs at about 150 MHz at 4 x 4, 8 x 8
and 12 x 12; the baseline falls from 138 to 117 to 99 MHz, which leaves the
systolic array 45 % ahead at 12 x 12. With multiplier blocks the two are equal
up to 8 x 8 and 25 - 35 % apart at 12 x 12.

What the timing reports show:

* 8 x 8, LUT multipliers. Systolic: the critical path starts at the
  forwarding register of the neighbouring PE, and the net to the multiplier is
  0.9 ns long, two tiles away. Baseline: the critical path starts at an edge
  register, and the net to the multiplier is 3.6 ns long, from one side of the
  array to the other. The logic on the two paths is the same 2.5 - 2.7 ns.
* ECP5 multiplier blocks exist only in a few fixed rows, so with block
  multipliers a PE's registers and its multiplier can be far apart whichever
  way the operands arrive. That is why the two architectures stay together
  for longer there, and why the spread between seeds is large (107 - 146 MHz
  for the 8 x 8 systolic array).
* Routing is 60 % or more of every critical path. This is the regime in
  which neighbour-only wiring pays: on the ASIC the same comparison only
  showed a difference once the logic of the accumulate stage had been
  shortened.

The price is the forwarding registers: 12 % more flip-flops than the baseline
at 4 x 4, 26 % at 12 x 12.

## The ASIC datapath options on this FPGA

8 x 8 arrays, multipliers from LUTs, Fmax in MHz, worst - best of three seeds:

| Datapath | systolic | broadcast | LUT4, systolic | Flip-flops, systolic |
|----------|----------|-----------|---------------:|---------------------:|
| plain | 146 - 152 | 114 - 120 | 21 807 | 4697 |
| `ACC_SEG = 8` | 144 - 150 | 115 - 120 | 22 091 | 5427 |
| `MUL_CS = 1`, `ACC_SEG = 4` | 171 - 194 | 124 - 144 | 23 880 | 6403 |

* **Saved carries alone do nothing here**, as on the Zynq: the accumulator
  sits on the fabric's carry chain and was never the critical path.
* **The multiplier without a final adder is 17 - 28 % faster**, for 10 % more
  LUTs and 36 % more flip-flops. This was not expected. The critical path of
  the plain array is register -> multiplier -> product register with 2.5 ns
  of logic; the compressor tree without the final adder has 1.5 ns, and the
  critical path moves to the accumulate stage. Whether the same holds with
  Vivado, which builds a tighter LUT multiplier, has not been measured.

## Product register

8 x 8 systolic array, block multipliers:

| `PE_PIPE` | Fmax (MHz) | Flip-flops |
|-----------|------------|-----------:|
| 0         | 73 - 100   | 3664 |
| 1         | 107 - 146  | 4697 |

The register between multiplier and adder raises Fmax by about 45 % for 1033
flip-flops (about 16 per PE). Yosys does not pack it into the multiplier
block's own output register, so on ECP5 it is built from fabric flip-flops and
the path still leaves the block.

## Reproducing

See [syn/README.md](../syn/README.md).
