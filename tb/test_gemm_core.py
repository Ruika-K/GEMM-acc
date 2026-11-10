"""cocotb tests for gemm_core.

Four independent agents talk to the core through its valid / ready streams:
command, D rows, A/B beats and the C consumer. Each has its own random stall
pattern, so the tests exercise the controller, the skew lines and the output
credits together. The reference is numpy.
"""

import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, with_timeout
from cocotb.utils import get_sim_time

from util import pack, random_matrix, to_signed

CLK_NS = 10
SEED = int(os.environ.get("TB_SEED", "1"))


class CoreParams:
    def __init__(self, dut):
        self.data_w = int(dut.DATA_W.value)
        self.acc_w = int(dut.ACC_W.value)
        self.rows = int(dut.ROWS.value)
        self.cols = int(dut.COLS.value)
        self.pipe = int(dut.PE_PIPE.value)
        self.k_max = int(dut.K_MAX.value)
        self.out_depth = int(dut.OUT_DEPTH.value)


class Tile:
    """One command plus its operands. A, B and D are generated at full array
    size; everything outside m x n is garbage the core must ignore."""

    def __init__(self, p, rng, m, n, k, has_d, mode="random"):
        self.m, self.n, self.k, self.has_d = m, n, k, has_d
        self.a = random_matrix(rng, (p.rows, k), p.data_w, mode)
        self.b = random_matrix(rng, (k, p.cols), p.data_w, mode)
        self.d = random_matrix(rng, (p.rows, p.cols), 2 * p.data_w)

    def expected(self, p):
        c = np.zeros((self.m, p.cols), dtype=np.int64)
        c[:, : self.n] = self.a[: self.m, :] @ self.b[:, : self.n]
        if self.has_d:
            c[:, : self.n] += self.d[: self.m, : self.n]
        return c


def cycle():
    return int(get_sim_time("ns")) // CLK_NS


async def reset(dut):
    dut.rst_n.value = 0
    dut.cmd_valid_i.value = 0
    dut.d_valid_i.value = 0
    dut.ab_valid_i.value = 0
    dut.c_ready_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_stream(dut, valid, ready, items, apply, rng, p_valid, fired_at=None):
    """Generic valid / ready source. apply(item) drives the payload; apply(None)
    drives garbage while valid is low."""
    for item in items:
        while rng.random() >= p_valid:
            valid.value = 0
            apply(None)
            await RisingEdge(dut.clk)
        valid.value = 1
        apply(item)
        while True:
            await ReadOnly()
            fired = int(ready.value) == 1
            now = cycle()
            await RisingEdge(dut.clk)
            if fired:
                if fired_at is not None:
                    fired_at.append(now)
                break
    valid.value = 0
    apply(None)


async def collect(dut, p, n_rows, rng, p_ready, rows):
    """C consumer with random back-pressure."""
    while len(rows) < n_rows:
        dut.c_ready_i.value = 1 if rng.random() < p_ready else 0
        await ReadOnly()
        if int(dut.c_valid_o.value) and int(dut.c_ready_i.value):
            word = int(dut.c_o.value)
            mask = (1 << p.acc_w) - 1
            vals = [to_signed((word >> (j * p.acc_w)) & mask, p.acc_w) for j in range(p.cols)]
            rows.append((vals, int(dut.c_last_o.value)))
        await RisingEdge(dut.clk)
    dut.c_ready_i.value = 0


async def run(dut, tiles, p_valid=1.0, p_ready=1.0, seed=0):
    """Push the tiles through the core and check every result row.
    Returns the cycle numbers of all accepted A/B beats."""
    p = CoreParams(dut)
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    dmask = (1 << p.data_w) - 1

    def apply_cmd(t):
        if t is None:
            dut.cmd_m_i.value = rng.randint(0, p.rows)
            dut.cmd_n_i.value = rng.randint(0, p.cols)
            dut.cmd_k_i.value = rng.randint(0, p.k_max)
            dut.cmd_has_d_i.value = rng.randint(0, 1)
        else:
            dut.cmd_m_i.value = t.m
            dut.cmd_n_i.value = t.n
            dut.cmd_k_i.value = t.k
            dut.cmd_has_d_i.value = int(t.has_d)

    def apply_d(row):
        if row is None:
            dut.d_i.value = rng.getrandbits(p.cols * p.acc_w)
        else:
            dut.d_i.value = pack(row, p.acc_w)

    def apply_ab(beat):
        if beat is None:
            dut.a_i.value = rng.getrandbits(p.rows * p.data_w)
            dut.b_i.value = rng.getrandbits(p.cols * p.data_w)
        else:
            dut.a_i.value = pack(beat[0], p.data_w)
            dut.b_i.value = pack(beat[1], p.data_w)

    d_items, ab_items, expect = [], [], []
    for t in tiles:
        if t.has_d:
            d_items += [[int(v) for v in t.d[r, :]] for r in range(t.m)]
        ab_items += [
            ([int(v) for v in t.a[:, k]], [int(v) for v in t.b[k, :]]) for k in range(t.k)
        ]
        c = t.expected(p)
        expect += [([int(v) for v in c[r, :]], int(r == t.m - 1)) for r in range(t.m)]

    ab_fired, rows = [], []
    # Separate random streams so the stall patterns are independent.
    rngs = [random.Random(seed * 7919 + i) for i in range(4)]
    cocotb.start_soon(
        drive_stream(dut, dut.cmd_valid_i, dut.cmd_ready_o, tiles, apply_cmd, rngs[0], p_valid)
    )
    cocotb.start_soon(
        drive_stream(dut, dut.d_valid_i, dut.d_ready_o, d_items, apply_d, rngs[1], p_valid)
    )
    cocotb.start_soon(
        drive_stream(
            dut, dut.ab_valid_i, dut.ab_ready_o, ab_items, apply_ab, rngs[2], p_valid, ab_fired
        )
    )
    collector = cocotb.start_soon(collect(dut, p, len(expect), rngs[3], p_ready, rows))

    # Generous but finite: a hung handshake should fail quickly.
    budget = 200 + sum(t.k + 6 * p.rows + 4 * p.cols for t in tiles)
    budget = int(3 * budget / min(p_valid, p_ready))
    await with_timeout(collector, budget * CLK_NS, "ns")

    for idx, (got, exp) in enumerate(zip(rows, expect)):
        assert got == exp, f"result row {idx}: expected {exp}, got {got}"

    # Nothing else may come out, and the core must report idle.
    dut.c_ready_i.value = 1
    for _ in range(3 * p.rows + 2 * p.cols + 8):
        await ReadOnly()
        assert int(dut.c_valid_o.value) == 0, "unexpected extra result row"
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.idle_o.value) == 1, "core is not idle after the last tile"
    return ab_fired


def random_tiles(p, rng, count, k_hi=20):
    return [
        Tile(
            p,
            rng,
            m=rng.randint(1, p.rows),
            n=rng.randint(1, p.cols),
            k=rng.randint(1, k_hi),
            has_d=rng.random() < 0.5,
        )
        for _ in range(count)
    ]


@cocotb.test()
async def single_tile(dut):
    """One full-size tile without addend: the result is drained without a
    following command."""
    p = CoreParams(dut)
    rng = random.Random(SEED)
    await run(dut, [Tile(p, rng, p.rows, p.cols, p.rows, False)], seed=SEED)


@cocotb.test()
async def single_tile_with_d(dut):
    p = CoreParams(dut)
    rng = random.Random(SEED + 1)
    await run(dut, [Tile(p, rng, p.rows, p.cols, 5, True)], seed=SEED + 1)


@cocotb.test()
async def random_shapes(dut):
    """Random m, n, k and has_d, no stalls."""
    p = CoreParams(dut)
    rng = random.Random(SEED + 2)
    await run(dut, random_tiles(p, rng, 30), seed=SEED + 2)


@cocotb.test()
async def random_stalls(dut):
    """Every stream stalls independently half of the time."""
    p = CoreParams(dut)
    rng = random.Random(SEED + 3)
    await run(dut, random_tiles(p, rng, 30), p_valid=0.5, p_ready=0.5, seed=SEED + 3)


@cocotb.test()
async def slow_consumer(dut):
    """Heavy back-pressure on C: the output credits must hold the drain back."""
    p = CoreParams(dut)
    rng = random.Random(SEED + 4)
    await run(dut, random_tiles(p, rng, 12, k_hi=6), p_ready=0.1, seed=SEED + 4)


@cocotb.test()
async def slow_producers(dut):
    """Starved inputs, fast consumer."""
    p = CoreParams(dut)
    rng = random.Random(SEED + 5)
    await run(dut, random_tiles(p, rng, 12, k_hi=6), p_valid=0.15, seed=SEED + 5)


@cocotb.test()
async def extreme_values(dut):
    p = CoreParams(dut)
    rng = random.Random(SEED + 6)
    tiles = [
        Tile(p, rng, p.rows, p.cols, 64, False, mode="min"),
        Tile(p, rng, p.rows, p.cols, 64, True, mode="max"),
    ]
    await run(dut, tiles, seed=SEED + 6)


@cocotb.test()
async def tile_period(dut):
    """With nothing stalling, consecutive tiles are K + 2 * ROWS - 1 cycles
    apart. This is the bound derived in docs/spec.md."""
    p = CoreParams(dut)
    rng = random.Random(SEED + 7)
    k = 16
    tiles = [Tile(p, rng, p.rows, p.cols, k, True) for _ in range(6)]
    fired = await run(dut, tiles, seed=SEED + 7)
    starts = fired[::k]
    periods = [b - a for a, b in zip(starts, starts[1:])]
    best = k + 2 * p.rows - 1
    if p.out_depth >= p.rows:
        assert periods == [best] * (len(tiles) - 1), f"tile periods {periods}, expected {best}"
    else:
        # A FIFO smaller than one tile makes the drain wait for credit.
        assert all(per >= best for per in periods), f"tile periods {periods} below {best}"
    dut._log.info("tile periods: %s (bound %d)", periods, best)
