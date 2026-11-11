"""cocotb tests for gemm_array.

The array has no skew logic of its own, so the testbench plays the role of the
future skew buffers and controller: it builds a cycle-by-cycle schedule for the
west / north / south edges, plays it back, and collects whatever leaves the
north edge while c_valid_o is high.
"""

import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from util import pack, random_matrix, to_signed


class ArrayParams:
    def __init__(self, dut):
        self.data_w = int(dut.DATA_W.value)
        self.acc_w = int(dut.ACC_W.value)
        self.rows = int(dut.ROWS.value)
        self.cols = int(dut.COLS.value)
        self.pipe = int(dut.PE_PIPE.value)


class Schedule:
    """Sparse per-cycle stimulus for the array edges."""

    def __init__(self, p):
        self.p = p
        self.a = {}      # (cycle, row) -> value, implies a_valid
        self.b = {}      # (cycle, col) -> value
        self.c = {}      # (cycle, col) -> preload value
        self.shift = set()
        self.length = 0

    def add_shift(self, ts, d, slots=None):
        """Shift phase starting at west-edge cycle ts, preloading matrix d.
        slots[r] is the time slot of shift beat r; gaps are stalled beats."""
        p = self.p
        if slots is None:
            slots = list(range(p.rows))
        for r, s in enumerate(slots):
            self.shift.add(ts + s)
            for j in range(p.cols):
                # Column j shifts j cycles later, plus the PE pipeline stage.
                self.c[(ts + s + j + p.pipe, j)] = int(d[r, j])
        self.length = max(self.length, ts + slots[-1] + p.cols + p.pipe + 1)
        return slots[-1] + 1  # number of slots consumed

    def add_compute(self, t0, a, b, slots=None):
        """Feed A (rows x K) and B (K x cols). slots[k] is the time slot used by
        index k; gaps between slots are bubbles (valid low)."""
        p = self.p
        k_dim = a.shape[1]
        if slots is None:
            slots = list(range(k_dim))
        for k, s in enumerate(slots):
            for i in range(p.rows):
                self.a[(t0 + i + s, i)] = int(a[i, k])
            for j in range(p.cols):
                self.b[(t0 + j + s, j)] = int(b[k, j])
        self.length = max(self.length, t0 + slots[-1] + p.rows + p.cols)
        return slots[-1] + 1  # number of slots consumed


async def reset(dut):
    dut.rst_n.value = 0
    dut.a_valid_i.value = 0
    dut.a_i.value = 0
    dut.b_i.value = 0
    dut.shift_i.value = 0
    dut.c_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def play(dut, p, sched, rng):
    """Drive the schedule; return, per column, the list of drained raw words."""
    drained = [[] for _ in range(p.cols)]
    dmask = (1 << p.data_w) - 1
    for cyc in range(sched.length + 2):
        a_valid = 0
        a_vals, b_vals, c_vals = [], [], []
        for i in range(p.rows):
            if (cyc, i) in sched.a:
                a_valid |= 1 << i
                a_vals.append(sched.a[(cyc, i)])
            else:
                # Garbage on idle cycles: must be ignored because valid is low.
                a_vals.append(rng.randint(0, dmask))
        for j in range(p.cols):
            b_vals.append(sched.b.get((cyc, j), rng.randint(0, dmask)))
            c_vals.append(sched.c.get((cyc, j), rng.getrandbits(p.acc_w)))

        dut.a_valid_i.value = a_valid
        dut.a_i.value = pack(a_vals, p.data_w)
        dut.b_i.value = pack(b_vals, p.data_w)
        dut.c_i.value = pack(c_vals, p.acc_w)
        dut.shift_i.value = 1 if cyc in sched.shift else 0

        if SETTLE_PS:
            await Timer(SETTLE_PS, "ps")
        await ReadOnly()
        c_valid = int(dut.c_valid_o.value)
        if c_valid:
            c_bits = dut.c_o.value
            for j in range(p.cols):
                if (c_valid >> j) & 1:
                    # Keep the raw slice: before the first preload it is X.
                    drained[j].append(c_bits[(j + 1) * p.acc_w - 1 : j * p.acc_w])
        await RisingEdge(dut.clk)
    return drained


async def run_tiles(dut, tiles, extra_gap=0, bubbles=False, seed=0):
    """Run a list of (A, B, D) tiles back to back and check C = A @ B + D.

    The drain of tile n and the preload of tile n + 1 share one shift phase,
    exactly as the real controller will do it.
    """
    p = ArrayParams(dut)
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    def gapped(count):
        if not bubbles:
            return None
        slots, s = [], 0
        for _ in range(count):
            s += rng.choice([0, 0, 1, 3])
            slots.append(s)
            s += 1
        return slots

    sched = Schedule(p)
    ts = 0
    for a, b, d in tiles:
        ts += rng.randint(0, extra_gap)
        used = sched.add_shift(ts, d, gapped(p.rows))
        # Earliest legal start: the slot right after the last shift beat.
        t0 = ts + used + rng.randint(0, extra_gap)
        used = sched.add_compute(t0, a, b, gapped(a.shape[1]))
        # Earliest legal next shift: the last operand of the last row (which
        # enters ROWS - 1 cycles after row 0) must have been accumulated.
        ts = t0 + used + p.rows - 1
    # Final shift phase drains the last tile.
    ts += rng.randint(0, extra_gap)
    sched.add_shift(ts, np.zeros((p.rows, p.cols), dtype=np.int64), gapped(p.rows))

    drained = await play(dut, p, sched, rng)

    for j in range(p.cols):
        assert len(drained[j]) == (len(tiles) + 1) * p.rows, (
            f"column {j}: drained {len(drained[j])} words"
        )
    for n, (a, b, d) in enumerate(tiles):
        expect = a @ b + d
        got = np.zeros_like(expect)
        for r in range(p.rows):
            for j in range(p.cols):
                # Skip the first ROWS words: they are the power-up contents.
                raw = drained[j][(n + 1) * p.rows + r]
                got[r, j] = to_signed(int(raw), p.acc_w)
        assert np.array_equal(got, expect), (
            f"tile {n} mismatch\nexpected:\n{expect}\ngot:\n{got}"
        )


def make_tiles(p, rng, k_list, mode="random", zero_d=False):
    tiles = []
    for k in k_list:
        a = random_matrix(rng, (p.rows, k), p.data_w, mode)
        b = random_matrix(rng, (k, p.cols), p.data_w, mode)
        if zero_d:
            d = np.zeros((p.rows, p.cols), dtype=np.int64)
        else:
            d = random_matrix(rng, (p.rows, p.cols), 2 * p.data_w)
        tiles.append((a, b, d))
    return tiles


SEED = int(os.environ.get("TB_SEED", "1"))
# Gate-level runs delay the inputs after the clock edge (see syn/asic/gls.py);
# outputs that depend combinationally on an input are sampled after that delay.
SETTLE_PS = int(os.environ.get("TB_SETTLE_PS", "0"))


@cocotb.test()
async def single_tile(dut):
    """One tile, no addend, tightest legal timing."""
    p = ArrayParams(dut)
    rng = random.Random(SEED)
    await run_tiles(dut, make_tiles(p, rng, [p.rows], zero_d=True), seed=SEED)


@cocotb.test()
async def back_to_back_tiles(dut):
    """Several tiles with different K, drain and preload overlapped."""
    p = ArrayParams(dut)
    rng = random.Random(SEED + 1)
    await run_tiles(dut, make_tiles(p, rng, [1, 2, 7, 33, 1, 16]), seed=SEED + 1)


@cocotb.test()
async def idle_gaps(dut):
    """Random idle time between phases must not change the result."""
    p = ArrayParams(dut)
    rng = random.Random(SEED + 2)
    await run_tiles(
        dut, make_tiles(p, rng, [5, 12, 3, 9]), extra_gap=6, seed=SEED + 2
    )


@cocotb.test()
async def bubbles_in_stream(dut):
    """Empty slots in the operand stream and stalled shift beats are harmless."""
    p = ArrayParams(dut)
    rng = random.Random(SEED + 3)
    await run_tiles(
        dut, make_tiles(p, rng, [8, 20, 1, 13]), bubbles=True, seed=SEED + 3
    )


@cocotb.test()
async def extreme_values(dut):
    """Most negative x most negative is the largest product: (-2^(W-1))^2."""
    p = ArrayParams(dut)
    rng = random.Random(SEED + 4)
    tiles = make_tiles(p, rng, [64], mode="min") + make_tiles(p, rng, [64], mode="max")
    a = random_matrix(rng, (p.rows, 64), p.data_w, "min")
    b = random_matrix(rng, (64, p.cols), p.data_w, "max")
    d = random_matrix(rng, (p.rows, p.cols), 2 * p.data_w)
    tiles.append((a, b, d))
    await run_tiles(dut, tiles, seed=SEED + 4)
