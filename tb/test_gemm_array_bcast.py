"""cocotb test for the broadcast baseline array (syn/common/gemm_array_bcast.sv).

The baseline exists only for the synthesis comparison, but a comparison against
a design that computes something else would be meaningless, so it gets the same
numpy check as the systolic array.
"""

import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from util import cpa_latency, pack, random_matrix, to_signed

SEED = int(os.environ.get("TB_SEED", "1"))


async def run_tile(dut, a, b, d, drained):
    """Preload d, accumulate a @ b, without any skew. Collects drained rows."""
    rows, cols = a.shape[0], b.shape[1]
    data_w, acc_w = int(dut.DATA_W.value), int(dut.ACC_W.value)

    async def step(valid=0, shift=0, a_col=None, b_row=None, c_row=None):
        dut.a_valid_i.value = valid
        dut.shift_i.value = shift
        dut.a_i.value = pack(a_col if a_col is not None else [0] * rows, data_w)
        dut.b_i.value = pack(b_row if b_row is not None else [0] * cols, data_w)
        dut.c_i.value = pack(c_row if c_row is not None else [0] * cols, acc_w)
        await ReadOnly()
        if int(dut.c_valid_o.value):
            drained.append(dut.c_o.value)
        await RisingEdge(dut.clk)

    # The preload value must be present when the delayed shift reaches the
    # accumulators: 1 cycle for the edge register, 1 more with PE_PIPE.
    lat = 1 + int(dut.PE_PIPE.value)
    sched = {}
    for r in range(rows):
        sched.setdefault(r, {})["shift"] = 1
        sched.setdefault(r + lat, {})["c_row"] = [int(v) for v in d[r, :]]
    t0 = rows
    for k in range(a.shape[1]):
        sched.setdefault(t0 + k, {}).update(
            valid=1, a_col=[int(v) for v in a[:, k]], b_row=[int(v) for v in b[k, :]]
        )
    for cyc in range(t0 + a.shape[1] + lat + 1 + cpa_latency(dut)):
        await step(**sched.get(cyc, {}))


@cocotb.test()
async def matches_numpy(dut):
    rows, cols = int(dut.ROWS.value), int(dut.COLS.value)
    data_w, acc_w = int(dut.DATA_W.value), int(dut.ACC_W.value)
    rng = random.Random(SEED)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.a_valid_i.value = 0
    dut.shift_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    tiles, drained = [], []
    for k in (1, 5, 17):
        a = random_matrix(rng, (rows, k), data_w)
        b = random_matrix(rng, (k, cols), data_w)
        d = random_matrix(rng, (rows, cols), 2 * data_w)
        tiles.append((a, b, d))
        await run_tile(dut, a, b, d, drained)
    zero = np.zeros((rows, cols), dtype=np.int64)
    await run_tile(dut, np.zeros((rows, 1), dtype=np.int64), np.zeros((1, cols), dtype=np.int64),
                   zero, drained)

    assert len(drained) == (len(tiles) + 1) * rows
    for n, (a, b, d) in enumerate(tiles):
        exp = a @ b + d
        for r in range(rows):
            word = int(drained[(n + 1) * rows + r])
            got = [to_signed((word >> (j * acc_w)) & ((1 << acc_w) - 1), acc_w) for j in range(cols)]
            assert got == [int(v) for v in exp[r, :]], f"tile {n} row {r}: {got} != {exp[r, :]}"
