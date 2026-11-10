# GEMM accelerator specification

Status legend: **[done]** implemented and verified in simulation,
**[planned]** specified but not implemented yet.

## 1. Function

```
C[M x N] = A[M x K] * B[K x N] + D[M x N]
```

* A, B: signed integers, `DATA_W` bits (default int8).
* D: optional signed addend, `ACC_W` bits (bias, or a partial result to keep
  accumulating into).
* C: signed, `ACC_W` bits. Optional requantisation (arithmetic right shift,
  saturation, ReLU) on the way out **[planned]**.

The BLAS scalars `alpha` and `beta` are deliberately not supported: they cost
two extra multipliers per output and quantised inference does not need them.

`M`, `K` and `N` are run-time values. The array size is a compile-time value.
`gemm_core` handles one tile (`M <= ROWS`, `N <= COLS`) **[done]**; larger
matrices are processed tile by tile by the layer above it **[planned]**.

## 2. Architecture

```
            +-----------+
 AXI4-Lite -|   CSRs    |---- tile loop                               [planned]
            +-----------+        |
                                 v cmd
 AXI4-Stream --> input buffers --> gemm_core --> requant --> AXI4-Stream
   (A, B, D)        [planned]        [done]     [planned]        (C)
```

Inside `gemm_core`:

```
          +------+   beats   +----------+     +-------+     +---------+
 cmd ---> | ctrl | --------> | input    | --> | skew  | --> |  array  |
 d, ab -> |      |           | register |     | lines |     |         |
          +------+           +----------+     +-------+     +---------+
             ^ credit                                            |
             |                 +------+     +---------+          |
 c  <--------+-----------------| FIFO | <-- | de-skew | <--------+
                               +------+     +---------+
```

| Module       | Role |
|--------------|------|
| `gemm_pe`    | Processing element |
| `gemm_array` | `ROWS x COLS` mesh of PEs, no skew logic |
| `gemm_delay` | Fixed delay line used for skew and de-skew |
| `gemm_fifo`  | Output FIFO |
| `gemm_ctrl`  | Tile sequencer and output credits |
| `gemm_core`  | Wires the above together |

### 2.1 Output-stationary systolic array **[done]**

Each PE owns one element of C and accumulates it in place.

| Signal            | Direction      | Registered per PE |
|-------------------|----------------|-------------------|
| A operand + valid | west -> east   | yes               |
| B operand         | north -> south | yes               |
| shift control     | west -> east   | yes               |
| accumulator chain | south -> north | (the accumulator) |

Every connection is between neighbouring PEs. The only signal with fan-out
larger than one PE is `shift_i`, which feeds the `ROWS` PEs of the west column.

Why output-stationary: the `K` dimension is unrolled in time, so `K` is not
limited by the array size. Only `M` and `N` have to be tiled.

### 2.2 Processing element **[done]**

```
if (shift)          acc <= c_i;             // drain / preload
else if (mac_valid) acc <= acc + a * b;     // accumulate
```

`shift` has priority over accumulation. With `PE_PIPE = 1` the product is
registered before it reaches the adder, and the shift control is taken one
stage later as well, so that operands and shift control have the same latency
to the accumulator. The phase spacing rules in section 4 therefore do not
depend on `PE_PIPE`.

Only control registers (valid, shift) are reset. Operand, product and
accumulator registers are not: the shift phase that starts every tile
overwrites the accumulators.

### 2.3 Skew and de-skew **[done]**

All beats are registered once at the core boundary and then delayed:

| Path | Delay (cycles) |
|------|----------------|
| A, row `i` (data and valid) | `i` |
| B, column `j` | `j` |
| D, column `j` | `j + PE_PIPE` |
| shift control | 0 |
| C, column `j` (after the array) | `COLS - 1 - j` |
| result tag (valid, last) | `COLS - 1 + PE_PIPE` |

Data delay lines have no reset so that FPGA tools can map them onto
shift-register LUTs. Only the 1-bit valid and tag lines are reset.

### 2.4 Controller **[done]**

The controller knows nothing about skew. It issues two kinds of beats:

* **shift beat**: one step of the accumulator chains. It drains one row of the
  tile that was just computed and preloads one row of the next tile.
* **operand beat**: one column of A and one row of B.

```
IDLE --cmd--> SHIFT --ROWS beats--> MAC --K beats--> WAIT --ROWS-1 cycles--+
                ^                                                         |
                +---------------------------------------------------------+
```

* `SHIFT`: a beat is issued when the D row it needs is valid and an output
  FIFO slot is available for the result row it releases. Beats do not have to
  be consecutive.
* `MAC`: a beat is issued on every A/B handshake. A missing beat is simply an
  empty slot in the array.
* `WAIT`: the last array row receives its operands `ROWS - 1` cycles late.
* One command is buffered. If it is already waiting when a tile finishes, its
  preload shares the shift phase with the drain of that tile; otherwise the
  tile is drained on its own and the core returns to idle.

Nothing in the core is ever stalled by a global enable: a stalled stream only
means that fewer beats are issued.

**Output flow control.** A result row reaches the output FIFO `COLS + PE_PIPE`
cycles after the decision to release it, so a plain ready signal would arrive
too late. The controller keeps a credit counter, initialised to `OUT_DEPTH`,
decremented when a result row is released and incremented when a row leaves
the FIFO. The FIFO can never overflow.

## 3. Parameters

### 3.1 Compile time

| Parameter   | Default | Meaning |
|-------------|---------|---------|
| `DATA_W`    | 8       | Operand width, signed |
| `ROWS`      | 8       | Array rows (tile size in M) |
| `COLS`      | 8       | Array columns (tile size in N) |
| `ACC_W`     | 32      | Accumulator width, signed |
| `PE_PIPE`   | 1       | 1: register between multiplier and adder |
| `K_MAX`     | 1024    | Largest K per tile, sizes the K counter |
| `OUT_DEPTH` | `ROWS`  | Output FIFO depth in rows |

Accumulator sizing: the largest product magnitude is `2^(2*DATA_W-2)`, so `K`
products fit in `2*DATA_W + ceil(log2(K))` bits. For int8 and `K_MAX = 1024`
that is 26 bits. The default of 32 leaves headroom for D and matches the int32
bias convention of quantised networks.

`OUT_DEPTH` can be any value from 1. With `OUT_DEPTH >= ROWS` a whole tile can
be drained without waiting for the consumer.

### 3.2 Run time

Per tile, on the `cmd` stream of `gemm_core` **[done]**:

| Field   | Range        | Meaning |
|---------|--------------|---------|
| `m`     | 1 .. `ROWS`  | Rows of this tile |
| `n`     | 1 .. `COLS`  | Columns of this tile |
| `k`     | 1 .. `K_MAX` | Inner dimension |
| `has_d` | 0 / 1        | Take `m` rows from the D stream; otherwise start from zero |

Whole-matrix CSRs (`M`, `K`, `N`, `SHIFT`, `RELU_EN`, `CTRL`, `STATUS`)
**[planned]**.

## 4. Array timing contract **[done]**

`gemm_array` has no skew logic. Whatever drives it must follow this contract;
in `gemm_core` that is the controller plus the delay lines. Cycle numbers refer
to the cycle in which a value is presented at an array edge.

**Operand slot** `t`:

```
a_i[i] = A[i][k], a_valid_i[i] = 1   at cycle t + i
b_i[j] = B[k][j]                     at cycle t + j
```

Row `i` is delayed by `i` cycles and column `j` by `j` cycles, so `A[i][k]`
and `B[k][j]` reach PE(i, j) in the same cycle, `t + i + j`. Slots may be
empty (valid low on every row).

**Shift beat** `s`: `shift_i` is high in cycle `s`. Column `j` shifts in cycle
`s + j + PE_PIPE`, and in that cycle

```
c_valid_o[j] = 1
c_o[j]       = next row of the previous result   (row 0 leaves first)
c_i[j]       = next row of the new addend        (row 0 enters first)
```

A shift phase is `ROWS` beats, not necessarily consecutive. One phase drains
the previous tile and preloads the next one.

**Spacing:**

```
first operand slot  >  last shift beat of the preload
next shift beat     >= last operand slot + ROWS
```

The minimum tile period is therefore `K + 2*ROWS - 1` cycles and the array
utilisation is `K / (K + 2*ROWS - 1)`. Both bounds are exercised at equality by
the array testbench, and `gemm_core` is checked to reach this period when no
stream stalls.

## 5. Interfaces

### 5.1 `gemm_core` **[done]**

All streams use valid / ready. Multi-word payloads are packed with element 0
in the least significant bits.

| Stream | Direction | Beats per tile | Payload |
|--------|-----------|----------------|---------|
| `cmd`  | in        | 1              | `m`, `n`, `k`, `has_d` |
| `d`    | in        | `m` if `has_d` | row of D: `COLS x ACC_W` |
| `ab`   | in        | `k`            | column of A: `ROWS x DATA_W`; row of B: `COLS x DATA_W` |
| `c`    | out       | `m`            | row of C: `COLS x ACC_W`; `c_last_o` on row `m - 1` |

* A is consumed column by column and B row by row.
* B and D columns `>= n` are ignored and C columns `>= n` read as zero. A rows
  `>= m` are ignored: those array rows still compute but are never drained.
* No ready output depends combinationally on a valid input.
* `idle_o` is high when no tile is in progress and every result row has left
  the output FIFO.

### 5.2 Top level **[planned]**

* Configuration: AXI4-Lite.
* Data: AXI4-Stream for A, B, D in and C out.

## 6. Verification

* cocotb testbenches, numpy reference model (`A @ B + D`).
* `gemm_array` is tested on its own with a testbench-generated edge schedule,
  so the timing contract is verified independently of the logic that
  implements it.
* `gemm_core` is tested through its four streams, each with an independent
  random stall pattern: random shapes, starved producers, a slow consumer,
  extreme operand values, FIFO depths from 1 to more than a tile, and a
  cycle-exact check of the tile period.
* Inputs carry random data whenever they are not valid, and operands outside
  `m x n` are random, so anything the core should ignore is actively wrong.
* Array sizes include non-square, single-row and 1 x 1; both `PE_PIPE`
  settings are covered.
* Lint: `verilator --lint-only -Wall`.

## 7. Roadmap

1. **[done]** PE and array, verified in simulation.
2. **[done]** Skew / de-skew lines, controller and output FIFO; run-time
   `m`, `n`, `k` per tile.
3. **[planned]** Tiling for arbitrary sizes, input buffers, AXI interfaces.
4. **[planned]** FPGA synthesis and implementation: Fmax, LUT / FF / DSP,
   throughput, and Fmax versus array size against a non-systolic baseline.
5. **[planned]** Extensions: weight-stationary mode, overlapping drain with the
   next compute phase, operand gating for unused rows, zero skipping.
