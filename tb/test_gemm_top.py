"""cocotb tests for gemm_top: the accelerator as a host sees it."""

import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, with_timeout

from gemm_host import (
    CTRL_LOAD_A,
    CTRL_LOAD_B,
    CTRL_START,
    REG_CFG,
    REG_CTRL,
    REG_DIM_K,
    REG_DIM_M,
    REG_DIM_N,
    REG_INFO,
    REG_STATUS,
    ST_BUSY,
    ST_DONE,
    ST_ERR,
    ST_LOADING,
    Host,
    stream_send,
    tile_order,
    untile,
)
from util import random_matrix

CLK_NS = 10
SEED = int(os.environ.get("TB_SEED", "1"))


class TopParams:
    def __init__(self, dut):
        for name in (
            "DATA_W", "ACC_W", "ROWS", "COLS", "PE_PIPE", "K_MAX",
            "OUT_DEPTH", "A_DEPTH", "B_DEPTH", "BIAS_DEPTH",
        ):
            setattr(self, name.lower(), int(getattr(dut, name).value))

    def fits(self, m, k, n):
        mt, nt = -(-m // self.rows), -(-n // self.cols)
        return (
            k <= self.k_max
            and mt * k <= self.a_depth
            and nt * k <= self.b_depth
            and nt <= self.bias_depth
        )


async def setup(dut, seed, **host_args):
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    dut.aresetn.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.m_axis_tready.value = 0
    rng = random.Random(seed)
    host = Host(dut, rng, **host_args)
    for _ in range(3):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    return TopParams(dut), rng, host


def operands(p, rng, m, k, n, bias=True, mode="random"):
    assert p.fits(m, k, n), f"test bug: {m}x{k}x{n} does not fit"
    a = random_matrix(rng, (m, k), p.data_w, mode)
    b = random_matrix(rng, (k, n), p.data_w, mode)
    d = random_matrix(rng, (1, n), 2 * p.data_w) if bias else None
    return a, b, d


def reference(a, b, bias):
    c = a @ b
    return c + bias if bias is not None else c


async def check(host, a, b, bias, budget_cycles=60000):
    got, cycles = await with_timeout(host.gemm(a, b, bias), budget_cycles * CLK_NS, "ns")
    exp = reference(a, b, bias)
    assert np.array_equal(got, exp), f"mismatch\nexpected:\n{exp}\ngot:\n{got}"
    return cycles


def random_dims(p, rng, max_tiles=3, k_hi=12):
    while True:
        m = rng.randint(1, max_tiles * p.rows)
        n = rng.randint(1, max_tiles * p.cols)
        k = rng.randint(1, k_hi)
        if p.fits(m, k, n):
            return m, k, n


@cocotb.test()
async def registers(dut):
    """Reset values, read-back and the INFO word."""
    p, _, host = await setup(dut, SEED)
    info = await host.axil.read(REG_INFO)
    assert info == (p.acc_w << 24) | (p.data_w << 16) | (p.cols << 8) | p.rows
    assert await host.status() == 0
    for reg, val in ((REG_DIM_M, 0x1234), (REG_DIM_K, 0x0055), (REG_DIM_N, 0xBEEF), (REG_CFG, 1)):
        assert await host.axil.read(reg) == 0
        await host.axil.write(reg, val)
        assert await host.axil.read(reg) == val
    # Byte strobes: only the low byte of DIM_M is replaced.
    await host.axil.write(REG_DIM_M, 0xFFFFFFAB, strb=0x1)
    assert await host.axil.read(REG_DIM_M) == 0x12AB
    assert await host.axil.read(REG_CTRL) == 0


@cocotb.test()
async def tile_order_model(dut):
    """The host-side reordering helpers are inverses of each other."""
    p, rng, _ = await setup(dut, SEED)
    c = random_matrix(rng, (2 * p.rows + 1, 3 * p.cols - 1 if p.cols > 1 else 3), 16)
    assert np.array_equal(untile(tile_order(c, p.rows, p.cols), *c.shape, p.rows, p.cols), c)


@cocotb.test()
async def single_tile(dut):
    p, rng, host = await setup(dut, SEED + 1)
    await check(host, *operands(p, rng, p.rows, 5, p.cols, bias=False))


@cocotb.test()
async def exact_tiles_with_bias(dut):
    p, rng, host = await setup(dut, SEED + 2)
    await check(host, *operands(p, rng, 2 * p.rows, 7, 3 * p.cols))


@cocotb.test()
async def ragged_shapes(dut):
    """Dimensions that are not multiples of the array size, K down to 1."""
    p, rng, host = await setup(dut, SEED + 3)
    shapes = [
        (2 * p.rows + 1, 3, p.cols + 1),
        (1, 1, 1),
        (p.rows + 1, 1, 2 * p.cols + 1),
        (3 * p.rows - 1 if p.rows > 1 else 3, 9, 1),
    ]
    for m, k, n in shapes:
        await check(host, *operands(p, rng, m, k, n, bias=rng.random() < 0.5))


@cocotb.test()
async def random_runs(dut):
    """Back-to-back runs with unrelated shapes: every run leaves stale data in
    the memories and in the unused lanes of the next one."""
    p, rng, host = await setup(dut, SEED + 4)
    for _ in range(8):
        m, k, n = random_dims(p, rng)
        await check(host, *operands(p, rng, m, k, n, bias=rng.random() < 0.5))


@cocotb.test()
async def reuse_operands(dut):
    """B and the bias stay loaded; only A is replaced between runs."""
    p, rng, host = await setup(dut, SEED + 5)
    m, k, n = 2 * p.rows, 6, 2 * p.cols + 1
    a, b, bias = operands(p, rng, m, k, n)
    await check(host, a, b, bias)
    for m2 in (m, p.rows + 1, 1):
        a2 = random_matrix(rng, (m2, k), p.data_w)
        await host.set_dims(m2, k, n, True)
        await host.load_a(a2)
        got, _ = await with_timeout(host.run(m2, n), 100000 * CLK_NS, "ns")
        assert np.array_equal(got, reference(a2, b, bias))
    # Same operands again, bias switched off by configuration only.
    await host.set_dims(1, k, n, False)
    got, _ = await with_timeout(host.run(1, n), 100000 * CLK_NS, "ns")
    assert np.array_equal(got, reference(a2, b, None))


@cocotb.test()
async def immediate_restart(dut):
    """START again right after TLAST, while the core may still be shifting the
    unused rows of the previous run out of the array."""
    p, rng, host = await setup(dut, SEED + 11)
    for m, k, n in ((1, 2, 1), (p.rows + 1, 3, p.cols + 1)):
        a, b, bias = operands(p, rng, m, k, n)
        exp = reference(a, b, bias)
        got, _ = await with_timeout(host.gemm(a, b, bias), 60000 * CLK_NS, "ns")
        assert np.array_equal(got, exp)
        for _ in range(3):
            got, _ = await with_timeout(host.run(m, n), 60000 * CLK_NS, "ns")
            assert np.array_equal(got, exp)


@cocotb.test()
async def stalls(dut):
    """Slow source, slow sink and delayed register accesses."""
    p, rng, host = await setup(dut, SEED + 6, p_valid=0.4, p_ready=0.3, axil_delay=3)
    for _ in range(4):
        m, k, n = random_dims(p, rng)
        await check(host, *operands(p, rng, m, k, n, bias=rng.random() < 0.5))


@cocotb.test()
async def extreme_values(dut):
    p, rng, host = await setup(dut, SEED + 7)
    k = min(64, p.a_depth // 2, p.b_depth // 2)
    for mode in ("min", "max"):
        await check(host, *operands(p, rng, p.rows + 1, k, p.cols + 1, mode=mode))


@cocotb.test()
async def rejected_requests(dut):
    """Illegal requests set ERR and change nothing."""
    p, rng, host = await setup(dut, SEED + 8)
    ax = host.axil

    # START with K = 0.
    await host.set_dims(2, 0, 2)
    await ax.write(REG_CTRL, CTRL_START)
    assert await host.status() == ST_ERR
    await ax.write(REG_STATUS, ST_ERR)          # write 1 to clear
    assert await host.status() == 0

    # K above K_MAX.
    await host.set_dims(2, p.k_max + 1, 2)
    await ax.write(REG_CTRL, CTRL_LOAD_A)
    assert await host.status() == ST_ERR
    await ax.write(REG_STATUS, ST_ERR)

    # Two requests in one write.
    await host.set_dims(2, 2, 2)
    await ax.write(REG_CTRL, CTRL_START | CTRL_LOAD_B)
    assert await host.status() == ST_ERR
    await ax.write(REG_STATUS, ST_ERR)

    # While loading: START is refused and the dimensions are write-protected.
    await ax.write(REG_CTRL, CTRL_LOAD_A)
    assert await host.status() == ST_LOADING
    await ax.write(REG_CTRL, CTRL_START)
    await ax.write(REG_DIM_M, 99)
    assert await host.status() == ST_LOADING | ST_ERR
    assert await ax.read(REG_DIM_M) == 2
    await stream_send(dut, [1, 2, 3, 4], rng)
    await ax.write(REG_STATUS, ST_ERR)
    assert await host.status() == 0

    # The accelerator still works afterwards.
    await check(host, *operands(p, rng, p.rows + 1, 3, p.cols + 1))


@cocotb.test()
async def load_overflow(dut):
    """A matrix that does not fit raises ERR; the stream is still consumed."""
    p, rng, host = await setup(dut, SEED + 9)
    k = p.a_depth // 2 + 1                       # two bands of K words: too many
    if k > p.k_max:
        return
    m = p.rows + 1
    await host.set_dims(m, k, 1)
    await host.load(CTRL_LOAD_A, [rng.randint(-128, 127) for _ in range(m * k)])
    assert await host.status() == ST_ERR
    await host.axil.write(REG_STATUS, ST_ERR)
    await check(host, *operands(p, rng, p.rows + 1, 4, p.cols + 1))


@cocotb.test()
async def throughput(dut):
    """Sixteen full tiles: the run takes one tile period per tile plus a fixed
    overhead, i.e. the drain / preload overlap survives the whole pipeline."""
    p, rng, host = await setup(dut, SEED + 10)
    k = p.rows * p.cols + 8                      # long enough that output keeps up
    m, n = 4 * p.rows, 4 * p.cols
    if not p.fits(m, k, n):
        return
    cycles = await check(host, *operands(p, rng, m, k, n))
    period = k + 2 * p.rows - 1
    ideal = 16 * period
    overhead = cycles - ideal
    dut._log.info("run: %d cycles = 16 x %d + %d", cycles, period, overhead)
    assert overhead >= 0
    if p.out_depth >= p.rows:
        # Preload of the first tile plus serialising the last one.
        assert overhead <= p.rows * p.cols + p.rows + 8, f"overhead {overhead}"
