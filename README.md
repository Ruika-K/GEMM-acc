# GEMM-acc

A parameterised integer matrix-multiply accelerator built around an
output-stationary systolic array, written in SystemVerilog.

```
C[M x N] = A[M x K] * B[K x N] + D[M x N]
```

## Status

Work in progress. `gemm_core` computes one tile (`m <= ROWS`, `n <= COLS`, any
`k`) end to end behind valid / ready streams and is verified in simulation.
Tiling for larger matrices, AXI interfaces and synthesis results are still to
come; see the roadmap in [docs/spec.md](docs/spec.md).

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

The exact timing contract of the array and the core interface are in
[docs/spec.md](docs/spec.md).

## Repository layout

```
rtl/gemm_pe.sv        processing element
rtl/gemm_array.sv     ROWS x COLS mesh of PEs
rtl/gemm_delay.sv     delay line for skew and de-skew
rtl/gemm_fifo.sv      output FIFO
rtl/gemm_ctrl.sv      tile sequencer and output credits
rtl/gemm_core.sv      one-tile GEMM engine (top level so far)
tb/                   cocotb tests and pytest runner
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

`make test` builds and simulates the array and the core for several parameter
combinations and checks every result against numpy. Set `TB_SEED` to change
the random seed.
