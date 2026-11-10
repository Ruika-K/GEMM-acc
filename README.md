# GEMM-acc

A parameterised integer matrix-multiply accelerator built around an
output-stationary systolic array, written in SystemVerilog.

```
C[M x N] = A[M x K] * B[K x N] + D[M x N]
```

## Status

Work in progress. The processing element and the `ROWS x COLS` array are
implemented and verified in simulation. Skew buffers, controller, tiling, AXI
interfaces and synthesis results are still to come; see the roadmap in
[docs/spec.md](docs/spec.md).

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
  `ACC_W` are compile-time parameters; `M`, `K`, `N` are run-time values.

The exact timing contract of the array is in
[docs/spec.md](docs/spec.md#4-array-timing-contract-done).

## Repository layout

```
rtl/gemm_pe.sv        processing element
rtl/gemm_array.sv     ROWS x COLS mesh of PEs
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

`make test` builds and simulates the array for several `(ROWS, COLS, PE_PIPE)`
combinations and checks every result against numpy.
