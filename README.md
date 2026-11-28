# GEMM-acc

A parameterised integer matrix-multiply accelerator built around an
output-stationary systolic array, written in SystemVerilog.

```
C[M x N] = A[M x K] * B[K x N] + bias[N]
```

## Status

The RTL is functionally complete and verified in simulation:
`gemm_top` takes matrices of run-time size over AXI4-Stream, stores them in
on-chip memories, tiles them over the array and streams the result back, with
AXI4-Lite registers for control.

Implementation results are in [docs/results.md](docs/results.md). The main
target is an ASIC flow on SkyWater sky130 with open tools (Yosys, OpenSTA,
OpenROAD):

* Place and route of the array: 4 x 4 and 8 x 8 fully routed with extracted
  parasitics, clock tree and hold repair. The 8 x 8 array reaches **198 MHz
  at the slow corner** (392 MHz typical) on 1.01 mm2.
* 16 x 16 placed and routed hierarchically: the PE hardened once as a macro
  (abstract, timing models, budgets at its pins) and tiled 256 times, then
  checked with a flat timing analysis of every netlist and extracted wire.
  **198 MHz at the slow corner, the same as 8 x 8**, on 4.45 mm2, in five
  minutes. The price of hierarchy is 15 - 20 % die area.
* The complete chip placed and routed: the 64 PE macros, 16 OpenRAM SRAM
  macros for the operand memories and 22 000 standard cells on 9.9 mm2,
  **189 MHz at the slow corner** (373 MHz typical) between registers, no
  routing violations, gate-level simulation of the routed netlist with the
  SRAM models. The PEs get a clock tree built by hand, an H-tree over the
  grid: 0.008 ns of skew between neighbouring PEs, where the tool's tree had
  0.55 ns. The SRAMs' own timing comes from models that cannot be trusted,
  so the paths through them are reported apart.
* Power from simulated activity: a gate-level simulation of the routed chip
  writes the switching of every net, OpenSTA turns it into power with the
  extracted parasitics. **31 - 44 pJ per multiply-accumulate** at the typical
  corner (the range is the SRAM models, which charge an access whether a
  macro is selected or not). Clock gating stops the datapath clock while the
  accelerator is idle: **idle power from 119 to 12 mW** at 100 MHz, with the
  clock tree rebuilt around the gate.
* Sign-off checks with the foundry's rules (Magic, Netgen, KLayout): the PE
  macro and the chip are clean in DRC, LVS (the chip: 21 225 devices,
  25 854 nets) and antenna. Getting there took patches for metal pieces the
  router left below the minimum area, a well tap for every n-well in the
  narrow channels between the PEs, and 699 antenna diodes.
* Static IR drop (OpenROAD's PDNSim, with the currents of the simulated
  workload): fed from the edges of the core, as from a pad ring, the first
  power grid lost **0.38 V** on the way to the middle of the die. A power
  ring and wider, twice as many met5 stripes bring it to **32 mV (1.8 %)**
  at 189 MHz, for 2 % of die area.
* The two steps that got it there from 89 MHz, both found by following the
  critical path. First the accumulator: it saves a carry every few bits
  instead of propagating it through 32 (`ACC_SEG`, 121 MHz). Then the
  multiplier: it stops at the two rows that leave its compressor tree and
  hands them to the accumulate stage unadded (`MUL_CS`, 198 MHz). A PE then
  has no carry chain longer than four bits.
* A measured comparison with a broadcast (non-systolic) array built from the
  same datapath netlist. With the plain datapath the two are equally fast up
  to 8 x 8, because the adder hides the wires. Without the carry chains the
  broadcast array is 17 % slower at 8 x 8, and the gap grows with the array.
* Synthesis of the complete accelerator with an 8 x 8 array: 193 kGE without
  the memories, 161 MHz at the slow corner before layout, as fast as the
  array alone. It was 125 MHz until the control logic was restructured:
  decisions as registers worked out a cycle ahead, a split down-counter, a
  FIFO with a registered head, and a technology mapping for delay.
* Verification: 65 simulated configurations from a single datapath module up
  to the AXI top level, among them a test that drives every operand pair
  through the hand-written multiplier, and gate-level simulation of the
  synthesised and of the routed netlists.

There are also FPGA prototypes: Lattice ECP5 with open tools (129 - 150 MHz
for the complete accelerator) and Xilinx Zynq-7000 with Vivado (163 MHz,
earlier RTL). On both, the systolic array keeps its frequency as it grows and a broadcast array
with the same datapath does not: about 150 MHz against 138 -> 99 MHz on the
ECP5 (4 x 4 to 12 x 12), 164 -> 158 MHz against 156 -> 139 MHz on the Zynq
(4 x 4 to 16 x 16).

## Design in brief

* **Output-stationary array.** A flows west to east, B flows north to south,
  and each PE accumulates one element of C in place. `K` is unrolled in time,
  so it is not limited by the array size.
* **Neighbour-only wiring.** Operands, valid and the shift control all move one
  PE per cycle. There is no global broadcast inside the array.
* **One chain for drain and preload.** During a shift phase the accumulators of
  each column form a shift register: results leave at the north edge while the
  addend D of the next tile enters at the south edge.
* **No long carry chain in the PE (optional).** With `ACC_SEG > 0` the
  accumulator keeps a few saved carries next to its sum; they are added in
  once per column where the results leave the array. With `MUL_CS = 1` the
  multiplier stops at the two rows that come out of its compressor tree and
  leaves their addition to the same mechanism.
* **Array size and matrix size are decoupled.** `ROWS`, `COLS`, `DATA_W`,
  `ACC_W` are compile-time parameters; `m`, `n`, `k` are run-time values.
* **No global stall.** The controller only decides whether to issue a shift
  beat or an operand beat in each cycle. A stalled input or output stream means
  fewer beats, never a frozen array.
* **Credit-based output.** Results need several cycles to leave the array, so
  the controller reserves an output FIFO slot before it releases a row.

* **Memories shaped like the array edge.** One memory word holds a whole column
  segment of A or row segment of B, so operands arrive at one beat per cycle.
  The host still sends plain row-major data; all address arithmetic is done
  with counters and adders.
* **One tile iterator per stream.** Commands, operands, bias and results each
  walk the tile sequence at their own pace, which keeps the streams decoupled
  and lets the next tile be queued while the current one is computing.

The timing contract of the array, the register map and the host sequence are
in [docs/spec.md](docs/spec.md).

## Repository layout

```
rtl/gemm_mac.sv       multiply-accumulate datapath of a PE
rtl/gemm_mac_cs.sv    the same with a multiplier that has no final adder
rtl/gemm_pe.sv        processing element
rtl/gemm_cpa.sv       pipelined adder for the saved carries
rtl/gemm_array.sv     ROWS x COLS mesh of PEs
rtl/gemm_delay.sv     delay line for skew and de-skew
rtl/gemm_fifo.sv      output FIFO
rtl/gemm_ctrl.sv      tile sequencer and output credits
rtl/gemm_core.sv      one-tile GEMM engine
rtl/gemm_mem.sv       operand memory with lane writes
rtl/gemm_load.sv      input stream to memory layout
rtl/gemm_tile_iter.sv tile iterator
rtl/gemm_seq.sv       commands, operands and bias for the core
rtl/gemm_out.sv       result serialiser
rtl/gemm_csr.sv       AXI4-Lite registers
rtl/gemm_top.sv       top level
tb/                   cocotb tests, pytest runner, host model (gemm_host.py)
syn/                  synthesis flows, baseline array, array harness
docs/results.md       implementation results
docs/spec.md          specification and roadmap
```

## Running the tests

Requirements: Python 3, Icarus Verilog 12 or newer, and Verilator for lint.

```bash
pip install -r requirements.txt
```

```bash
make lint
```

```bash
make test
```

`make test` builds and simulates the array, the core and the top level for
several parameter combinations and checks every result against numpy. Set `TB_SEED` to change
the random seed.
