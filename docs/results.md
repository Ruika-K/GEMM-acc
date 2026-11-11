# Implementation results

Two kinds of results: ASIC logic synthesis on an open 130 nm process, which
is the main target, and an FPGA implementation used as a prototype.

| Flow | State |
|------|-------|
| ASIC, sky130, synthesis and pre-layout timing | done |
| ASIC, place and route | not started |
| FPGA, Lattice ECP5 (Yosys + nextpnr) | done |
| FPGA, Xilinx (Vivado) | three-job smoke test passed, full sweep pending |

# ASIC: SkyWater sky130

Flow: `syn/asic/run.py`, numbers in `syn/asic/results.csv`. Yosys maps the RTL
to the `sky130_fd_sc_hd` standard-cell library, OpenSTA analyses timing.

* Corners: typical (tt, 25 C, 1.80 V) and slow (ss, 100 C, 1.60 V).
* Frequencies are for the worst register-to-register path at a 5 ns
  constraint.
* **These are pre-layout numbers.** No wire delay, no clock tree, no hold
  fixing. Area will grow and frequency will drop after place and route.
* The operand memories are SRAM macros in an ASIC. They are black boxes here
  and not part of any area figure.
* 1 gate equivalent (GE) = one `nand2_1` = 3.75 um2.

## Complete accelerator, 8 x 8 array

`gemm_top` without the memories: **156 kGE** (584 000 um2 of cells), 9739
flip-flops, **169 MHz typical, 80 MHz slow corner**.

Peak throughput is 64 multiply-accumulates per cycle: 5.1 GMAC/s at the slow
corner, 10.8 GMAC/s at the typical one.

Where the area goes (cells of each module type, not counting its submodules):

| Module | Instances | Area (um2) | Share |
|--------|----------:|-----------:|------:|
| `gemm_pe` | 64 | 388 480 | 66.5 % |
| `gemm_fifo` (output FIFO) | 1 | 92 200 | 15.8 % |
| `gemm_delay` (skew and de-skew) | 41 | 54 500 | 9.3 % |
| `gemm_core` (input register, glue) | 1 | 14 900 | 2.6 % |
| `gemm_tile_iter` | 4 | 8 800 | 1.5 % |
| `gemm_load` | 1 | 7 226 | 1.2 % |
| `gemm_csr` | 1 | 7 080 | 1.2 % |
| `gemm_seq` | 1 | 4 514 | 0.8 % |
| `gemm_ctrl` | 1 | 4 070 | 0.7 % |
| `gemm_out` | 1 | 2 410 | 0.4 % |

Two things stand out:

* **The output FIFO is 16 % of the logic.** It holds 8 rows of 257 bits in
  flip-flops. `OUT_DEPTH` is a parameter and the design is correct for any
  depth from 1, so this is a direct area / throughput trade.
* **The skew and de-skew lines are 9 %.** They are 2540 flip-flops, more than
  half as many as the array has, but the array's area is dominated by its
  multipliers and adders.

Memories that would be SRAM macros: A and B are 1024 x 64 bit each, bias is
64 x 256 bit.

## One processing element

| `PE_PIPE` | Area | Flip-flops |
|-----------|------|-----------:|
| 1 | 6052 um2 = 1.6 kGE | 66 |
| 0 | 6010 um2 = 1.6 kGE | 50 |

About a quarter of a PE is flip-flops; the rest is the 8 x 8 Booth multiplier,
the 32-bit accumulator adder and the load multiplexer.

## Array size, pipelining and adder architecture

| Design | Area (kGE) | Flip-flops | Fmax typical (MHz) | Fmax slow (MHz) |
|--------|-----------:|-----------:|-------------------:|----------------:|
| systolic 4 x 4 | 25.8 | 1056 | 160 | 80 |
| systolic 8 x 8 | 103.8 | 4224 | 165 | 80 |
| systolic 16 x 16 | 415.2 | 16 896 | 167 | 83 |
| broadcast 4 x 4 | 23.9 | 836 | 142 | 72 |
| broadcast 8 x 8 | 96.3 | 3204 | 140 | 71 |
| broadcast 16 x 16 | 381.8 | 12 548 | 135 | 69 |
| systolic 8 x 8, `PE_PIPE = 0` | 102.6 | 3200 | 136 | 69 |
| systolic 8 x 8, ripple-carry adder | 103.7 | 4224 | 154 | 80 |
| `gemm_core` 8 x 8 | 148.0 | 9299 | 168 | 83 |

* **The accumulate stage is the critical path**, not the multiplier: product
  register -> 32-bit adder -> load multiplexer -> accumulator. The default flow
  therefore maps carry chains to a Sklansky prefix adder, which is 7 % faster
  than ripple carry at the typical corner for no measurable area. At the slow
  corner the two are equal; that has not been analysed further.
* **The product register is worth 21 %** at the typical corner (136 -> 165 MHz)
  and 16 % at the slow one, for 1 % more area.
* **Systolic against broadcast, with a caveat.** The systolic array keeps its
  frequency from 4 x 4 to 16 x 16 and is 13 - 24 % faster than the baseline,
  which loses a little with every size step. The baseline is 7 - 8 % smaller.
  But the two are not mapped the same way: the systolic array is synthesised
  one PE at a time, the baseline as one flat module, and mapping the systolic
  array flat moved its result by as much as the gap between the two. Without
  wire delay this comparison cannot be settled; it needs place and route.

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

## Not done yet

* SRAM macros for the operand memories, and timing of the paths through them.
* Place and route (OpenROAD): wire delay, clock tree, hold, real area.
* Power: OpenSTA's default switching activity is not meaningful for a design
  that idles most of its control logic; it needs activity from simulation.
* Clock gating. Most registers have an enable.

# FPGA prototype: Lattice ECP5

All numbers in this part come from `syn/ecp5/run.py` and are stored in
`syn/ecp5/results.csv`. Device: LFE5UM-85F, speed grade 8, package CABGA756.
Every job is placed and routed with three seeds; frequencies are given as
worst - best seed. The Vivado flow (`syn/vivado/run.tcl`) has only passed a
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
