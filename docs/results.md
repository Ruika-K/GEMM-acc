# Implementation results

Status: the open-source flow (Yosys + nextpnr, Lattice ECP5) has been run. The
Vivado flow (`syn/vivado/run.tcl`) has not been run yet, so there are no Xilinx
numbers here.

All numbers below come from `syn/ecp5/run.py` and are stored in
`syn/ecp5/results.csv`. Device: LFE5UM-85F, speed grade 8, package CABGA756.
Every job is placed and routed with three seeds; frequencies are given as
worst - best seed.

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
