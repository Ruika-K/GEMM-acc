# GEMM accelerator specification

Status legend: **[done]** implemented and verified in simulation,
**[planned]** specified but not implemented yet.

## 1. Function

```
C[M x N] = A[M x K] * B[K x N] + bias[N]
```

* A, B: signed integers, `DATA_W` bits (default int8).
* bias: optional signed vector, `ACC_W` bits, added to every row of C. This is
  the fully connected layer of a quantised network: `M` input vectors, `K`
  inputs, `N` outputs.
* C: signed, `ACC_W` bits.

`M`, `K` and `N` are run-time values; the array size is a compile-time value.
Matrices larger than the array are processed tile by tile.

`gemm_core`, the engine underneath, supports a full `M x N` addend D rather
than a bias vector. The top level only exposes the bias form because a full D
costs `M x N x ACC_W` bits of memory for little practical use.

The BLAS scalars `alpha` and `beta` are deliberately not supported: they cost
two extra multipliers per output and quantised inference does not need them.

## 2. Architecture

```
            +------+        +-----------+
 s_axis --> | load | -----> | A/B/bias  | ---+
            +------+        | memories  |    | a, b, d
                            +-----------+    v
            +------+   cmd, read addresses +------+  rows  +-----+
 s_axi  --> | csr  | --start--> | seq | -> | core | -----> | out | --> m_axis
            +------+                       +------+        +-----+
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

| Module           | Role |
|------------------|------|
| `gemm_mac`       | Multiply-accumulate datapath of a PE |
| `gemm_pe`        | Processing element: forwarding registers around a `gemm_mac` |
| `gemm_array`     | `ROWS x COLS` mesh of PEs, no skew logic |
| `gemm_delay`     | Fixed delay line used for skew and de-skew |
| `gemm_fifo`      | Output FIFO |
| `gemm_ctrl`      | Tile sequencer and output credits |
| `gemm_core`      | One-tile engine: the modules above |
| `gemm_mem`       | Operand memory, one word per array edge |
| `gemm_load`      | Writes the row-major input stream into the memories |
| `gemm_tile_iter` | Walks the tiles of a matrix |
| `gemm_seq`       | Feeds commands, operands and bias to the core |
| `gemm_out`       | Serialises result rows |
| `gemm_csr`       | AXI4-Lite registers |
| `gemm_top`       | Top level |

All of it is **[done]**.

### 2.1 Output-stationary systolic array

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

### 2.2 Processing element

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

### 2.3 Skew and de-skew

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

### 2.4 Core controller

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

### 2.5 Operand memories

The array consumes a column segment of A (`ROWS` elements) and a row segment of
B (`COLS` elements) in every operand beat. To deliver them in one cycle, each
memory word holds one such segment:

```
A[i][k]  ->  a_mem   [(i / ROWS) * K + k],  lane i % ROWS
B[k][j]  ->  b_mem   [(j / COLS) * K + k],  lane j % COLS
bias[j]  ->  bias_mem[ j / COLS         ],  lane j % COLS
```

* Words are written one lane at a time (byte-write-enable style), so the host
  can send plain row-major data and the loader needs no buffering.
* For a given tile, both read addresses are `base + k`: they simply count up.
  Moving to another tile adds `K` to a base register. No multiplier or divider
  is used anywhere in the address logic.
* Lanes beyond the matrix edge are never written. They hold stale data, which
  the core ignores (section 5.1).

Capacity: `ceil(M / ROWS) * K <= A_DEPTH`, `ceil(N / COLS) * K <= B_DEPTH`,
`ceil(N / COLS) <= BIAS_DEPTH`.

### 2.6 Tiling

Tiles are visited in row-major order: for each band of `ROWS` result rows, for
each group of `COLS` result columns. The last tile of a band or of a column
group may be smaller.

The four streams that touch the core (commands, operands, bias, results) each
own a `gemm_tile_iter` and advance it at their own pace. The command of the
next tile is therefore offered to the core while the current tile is still
computing, which is the condition for the drain / preload overlap of 2.4.

The operand stream uses the registered memory output as its holding stage: a
new word is read whenever that stage is empty or its beat is being accepted,
which gives one beat per cycle without an extra skid buffer.

## 3. Parameters

| Parameter    | Default | Meaning |
|--------------|---------|---------|
| `DATA_W`     | 8       | Operand width, signed |
| `ROWS`       | 8       | Array rows (tile size in M) |
| `COLS`       | 8       | Array columns (tile size in N) |
| `ACC_W`      | 32      | Accumulator width, signed (at most 32) |
| `PE_PIPE`    | 1       | 1: register between multiplier and adder |
| `K_MAX`      | 1024    | Largest K, sizes the K counter |
| `OUT_DEPTH`  | `ROWS`  | Output FIFO depth in rows |
| `A_DEPTH`    | 1024    | A memory depth, words of `ROWS` elements |
| `B_DEPTH`    | 1024    | B memory depth, words of `COLS` elements |
| `BIAS_DEPTH` | 64      | Bias memory depth, words of `COLS` elements |
| `DIM_W`      | 16      | Width of the M, K, N registers |

Accumulator sizing: the largest product magnitude is `2^(2*DATA_W-2)`, so `K`
products fit in `2*DATA_W + ceil(log2(K))` bits. For int8 and `K_MAX = 1024`
that is 26 bits. The default of 32 leaves headroom for the bias and matches the
int32 bias convention of quantised networks.

`OUT_DEPTH` can be any value from 1. With `OUT_DEPTH >= ROWS` a whole tile can
be drained without waiting for the consumer.

## 4. Array timing contract

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
the array testbench; `gemm_core` and `gemm_top` are checked to reach this
period when nothing stalls.

## 5. Interfaces

### 5.1 `gemm_core`

All streams use valid / ready. Multi-word payloads are packed with element 0
in the least significant bits.

| Stream | Direction | Beats per tile | Payload |
|--------|-----------|----------------|---------|
| `cmd`  | in        | 1              | `m`, `n`, `k`, `has_d` (all sizes at least 1) |
| `d`    | in        | `m` if `has_d` | row of D: `COLS x ACC_W` |
| `ab`   | in        | `k`            | column of A: `ROWS x DATA_W`; row of B: `COLS x DATA_W` |
| `c`    | out       | `m`            | row of C: `COLS x ACC_W`; `c_last_o` on row `m - 1` |

* B and D columns `>= n` are ignored and C columns `>= n` read as zero. A rows
  `>= m` are ignored: those array rows still compute but are never drained.
* No ready output depends combinationally on a valid input.

### 5.2 Top level

| Port group | Protocol | Use |
|------------|----------|-----|
| `s_axi`    | AXI4-Lite, 32-bit data | Registers |
| `s_axis`   | AXI4-Stream, 32-bit `TDATA` | Operand elements, one per beat, in the low bits; `TLAST` not used |
| `m_axis`   | AXI4-Stream, 32-bit `TDATA` | Result elements, sign-extended, one per beat; `TLAST` on the last one |
| `irq_o`    | level | Follows `STATUS.DONE` |

One clock (`aclk`), synchronous active-low reset (`aresetn`).

**Registers**

| Offset | Name     | Access | Fields |
|--------|----------|--------|--------|
| 0x00   | `CTRL`   | W      | `[0] START` `[1] LOAD_A` `[2] LOAD_B` `[3] LOAD_BIAS`; write 1 to trigger, reads 0 |
| 0x04   | `STATUS` | R / W1C | `[0] BUSY` `[1] DONE` `[2] LOADING` `[3] ERR` (write 1 to clear `ERR`) |
| 0x08   | `DIM_M`  | RW     | Rows of A and C |
| 0x0C   | `DIM_K`  | RW     | Columns of A, rows of B |
| 0x10   | `DIM_N`  | RW     | Columns of B and C |
| 0x14   | `CFG`    | RW     | `[0] BIAS_EN` |
| 0x18   | `CYCLES` | R      | Clock cycles of the last run, `START` to last result element |
| 0x1C   | `INFO`   | R      | `[7:0] ROWS` `[15:8] COLS` `[23:16] DATA_W` `[31:24] ACC_W` |

* One `CTRL` request per write. A request is accepted only while neither
  `BUSY` nor `LOADING`, with the dimensions it needs in `1 .. 2^DIM_W - 1` and
  `K <= K_MAX`. Otherwise it is dropped and `ERR` is set.
* `DIM_*` and `CFG` are write-protected while `BUSY` or `LOADING`.
* `DONE` is set together with the last result element and cleared by the next
  `START`.
* `ERR` is also set when a load does not fit its memory. The stream is still
  consumed to the end, the out-of-range writes are dropped.

**Host sequence**

1. Write `DIM_M`, `DIM_K`, `DIM_N`, `CFG`.
2. Write `LOAD_A`, send `M * K` elements of A in row-major order.
3. Write `LOAD_B`, send `K * N` elements of B in row-major order.
4. If `BIAS_EN`: write `LOAD_BIAS`, send `N` elements.
5. Write `START`, receive `M * N` elements.

Operands stay in the memories. A later run can replace only one of them,
provided `K` and `N` are unchanged for a kept B, and `K` for a kept A.

**Result order.** Results leave tile by tile (row-major over tiles) and
row by row inside a tile; only valid elements are sent. For `N <= COLS` this is
plain row-major order. `tb/gemm_host.py` contains the reference reordering
(`untile`).

## 6. Verification

* cocotb testbenches, numpy reference model.
* Three levels, each with its own testbench:
  * `gemm_array` with a testbench-generated edge schedule, so the timing
    contract is verified independently of the logic that implements it;
  * `gemm_core` through its four streams, each with an independent random
    stall pattern;
  * `gemm_top` through AXI, driven by a host model that follows the sequence
    of section 5.2.
* Top-level tests: register access and byte strobes, exact and ragged matrix
  shapes down to 1 x 1 x 1, back-to-back runs with unrelated shapes (stale data
  in memories and unused lanes), reuse of loaded operands, restart immediately
  after `TLAST`, stalled streams and delayed register accesses, extreme values,
  rejected requests, load overflow, and a throughput check on a 16-tile run.
* Inputs carry random data whenever they are not valid, and operands outside
  the active region are random or stale, so anything that should be ignored is
  actively wrong.
* Array sizes include non-square, single-row and 1 x 1; both `PE_PIPE`
  settings and output FIFO depths from 1 upwards are covered.
* Lint: `verilator --lint-only -Wall`.

## 7. Roadmap

1. **[done]** PE and array, verified in simulation.
2. **[done]** Skew / de-skew lines, controller and output FIFO; run-time
   `m`, `n`, `k` per tile.
3. **[done]** Tiling, operand memories, AXI4-Lite and AXI4-Stream interfaces.
4. **[in progress]** Implementation, results in [results.md](results.md).
   * ASIC, sky130: logic synthesis, pre-layout timing and gate-level
     simulation are done; SRAM macros, place and route, power and clock gating
     are not.
   * FPGA prototype: ECP5 done; the Vivado sweep is still to be run.
5. **[planned]** Extensions, in no fixed order: output requantisation (shift,
   saturate, ReLU), row-major result order through a band buffer, several
   elements per input beat, weight-stationary mode, overlapping drain with the
   next compute phase, operand gating for unused rows, zero skipping.
