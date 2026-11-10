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
Matrices larger than the array are processed tile by tile **[planned]**.

## 2. Architecture

```
            +-----------+
 AXI4-Lite -|   CSRs    |---- controller (tile loop, phase timing)
            +-----------+            |
                                     v
 AXI4-Stream --> input buffers --> skew --> PE array --> de-skew --> requant --> AXI4-Stream
   (A, B, D)                              ROWS x COLS                               (C)
```

Only the PE array is implemented so far.

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
if (shift_i)        acc <= c_i;             // drain / preload
else if (mac_valid) acc <= acc + a * b;     // accumulate
```

`shift` has priority over accumulation. With `PE_PIPE = 1` the product is
registered before it reaches the adder.

Only control registers (valid, shift) are reset. Operand, product and
accumulator registers are not: the shift phase that starts every tile
overwrites the accumulators.

## 3. Parameters

### 3.1 Compile time

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `DATA_W`  | 8       | Operand width, signed |
| `ROWS`    | 8       | Array rows (tile size in M) |
| `COLS`    | 8       | Array columns (tile size in N) |
| `ACC_W`   | 32      | Accumulator width, signed |
| `PE_PIPE` | 1       | 1: register between multiplier and adder |
| `K_MAX`   | 1024    | Largest supported K **[planned]**, sizes counters |

Accumulator sizing: the largest product magnitude is `2^(2*DATA_W-2)`, so `K`
products fit in `2*DATA_W + ceil(log2(K))` bits. For int8 and `K_MAX = 1024`
that is 26 bits. The default of 32 leaves headroom for D and matches the int32
bias convention of quantised networks.

### 3.2 Run time (CSR) **[planned]**

| Register | Meaning |
|----------|---------|
| `M`, `K`, `N` | Matrix dimensions |
| `SHIFT`, `RELU_EN` | Output requantisation |
| `CTRL`, `STATUS` | start, busy, done, overflow flag |

## 4. Array timing contract **[done]**

The array has no skew logic. Whatever drives it must follow this contract.
Cycle numbers refer to the cycle in which a value is presented at an array edge.

**Compute phase**, starting at cycle `t0`:

```
a_i[i] = A[i][k], a_valid_i[i] = 1   at cycle t0 + i + k
b_i[j] = B[k][j]                     at cycle t0 + j + k
```

Row `i` is delayed by `i` cycles and column `j` by `j` cycles, so `A[i][k]`
and `B[k][j]` reach PE(i, j) in the same cycle, `t0 + i + j + k`.

A time slot `k` may be left empty (valid low on every row, with the same skew).
This is how a stalled input stream shows up at the array.

**Shift phase**, starting at cycle `ts`: `shift_i` is high for `ROWS` cycles.
Column `j` shifts during cycles `ts + j` to `ts + j + ROWS - 1`. In cycle
`ts + j + r`:

```
c_valid_o[j] = 1
c_o[j]       = C_previous[r][j]      (row 0 leaves first)
c_i[j]       = D_next[r][j]          (row 0 enters first)
```

One shift phase drains the previous tile and preloads the next one.

**Spacing:**

```
t0      >= ts + ROWS - PE_PIPE
ts_next >= t0 + K + ROWS - 1 + PE_PIPE
```

The minimum tile period is therefore `K + 2*ROWS - 1` cycles, independent of
`PE_PIPE`, and the array utilisation is `K / (K + 2*ROWS - 1)`. Both bounds are
exercised at equality by the testbench.

## 5. Interfaces **[planned]**

* Configuration: AXI4-Lite.
* Data: AXI4-Stream for A, B, D in and C out.

## 6. Verification

* cocotb testbench, numpy reference model (`A @ B + D`).
* The testbench generates the skewed edge schedule itself, so the array is
  verified independently of the skew buffers and controller that come next.
* Covered: tightest legal phase spacing, back-to-back tiles with different K
  (including K = 1), random idle gaps, empty slots in the operand stream,
  extreme operand values, non-square arrays, 1 x 1 array, both `PE_PIPE`
  settings.
* Lint: `verilator --lint-only -Wall`.

## 7. Roadmap

1. **[done]** PE and array, verified in simulation.
2. **[planned]** Skew / de-skew buffers and controller; run-time `M`, `K`, `N`
   up to the array size.
3. **[planned]** Tiling for arbitrary sizes, input buffers, AXI interfaces.
4. **[planned]** FPGA synthesis and implementation: Fmax, LUT / FF / DSP,
   throughput, and Fmax versus array size against a non-systolic baseline.
5. **[planned]** Extensions: weight-stationary mode, overlapping drain with the
   next compute phase, zero skipping.
