# GEMM-acc

A parameterised integer matrix-multiply accelerator built around an
output-stationary systolic array, written in SystemVerilog.

```
C[M x N] = A[M x K] * B[K x N] + bias[N]
```

## Status

Work in progress. The RTL is functionally complete and verified in simulation:
`gemm_top` takes matrices of run-time size over AXI4-Stream, stores them in
on-chip memories, tiles them over the array and streams the result back, with
AXI4-Lite registers for control.

Implementation results are in [docs/results.md](docs/results.md). The main
target is an ASIC flow on SkyWater sky130 with open tools (Yosys, OpenSTA,
OpenROAD):

* Synthesis of the complete accelerator with an 8 x 8 array: 157 kGE without
  the memories, 80 MHz at the slow corner before layout.
* Place and route of the array: 4 x 4 and 8 x 8 fully routed with extracted
  parasitics, clock tree and hold repair, about 90 MHz at the slow corner;
  16 x 16 placed and globally routed.
* A measured comparison with a broadcast (non-systolic) array built from the
  same datapath netlist. Up to 16 x 16 the broadcast array is as fast and
  5 - 6 % smaller; the document explains why and where that would change.
* Gate-level simulation of the synthesised and of the routed netlists.

There is also an FPGA prototype on a Lattice ECP5.

## Design in brief

* **Output-stationary array.** A flows west to east, B flows north to south,
  and each PE accumulates one element of C in place. `K` is unrolled in time,
  so it is not limited by the array size.
* **Neighbour-only wiring.** Operands, valid and the shift control all move one
  PE per cycle. There is no global broadcast inside the array.
* **One chain for drain and preload.** During a shift phase the accumulators of
  each column form a shift register: results leave at the north edge while the
  addend D of the next tile enters at the south edge.
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
rtl/gemm_pe.sv        processing element
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
