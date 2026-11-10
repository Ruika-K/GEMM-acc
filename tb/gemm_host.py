"""Host-side model of the accelerator: what a software driver has to do.

AxiLite, stream_send and stream_recv are minimal bus functional models. Host
strings them together into the register sequence of docs/spec.md, and
tile_order / untile describe the order in which results leave the accelerator.
"""

import cocotb
import numpy as np
from cocotb.triggers import ReadOnly, RisingEdge

REG_CTRL = 0x00
REG_STATUS = 0x04
REG_DIM_M = 0x08
REG_DIM_K = 0x0C
REG_DIM_N = 0x10
REG_CFG = 0x14
REG_CYCLES = 0x18
REG_INFO = 0x1C

CTRL_START = 1 << 0
CTRL_LOAD_A = 1 << 1
CTRL_LOAD_B = 1 << 2
CTRL_LOAD_BIAS = 1 << 3

ST_BUSY = 1 << 0
ST_DONE = 1 << 1
ST_LOADING = 1 << 2
ST_ERR = 1 << 3


def tile_order(c, rows, cols):
    """Flatten an M x N matrix in the order the accelerator emits it."""
    m, n = c.shape
    out = []
    for i0 in range(0, m, rows):
        for j0 in range(0, n, cols):
            out += [int(v) for v in c[i0 : i0 + rows, j0 : j0 + cols].flatten()]
    return out


def untile(flat, m, n, rows, cols):
    """Inverse of tile_order: rebuild the M x N matrix from the result stream."""
    c = np.zeros((m, n), dtype=np.int64)
    pos = 0
    for i0 in range(0, m, rows):
        for j0 in range(0, n, cols):
            tm, tn = min(rows, m - i0), min(cols, n - j0)
            c[i0 : i0 + tm, j0 : j0 + tn] = np.array(flat[pos : pos + tm * tn]).reshape(tm, tn)
            pos += tm * tn
    return c


async def _handshake(clk, valid, ready):
    valid.value = 1
    while True:
        await ReadOnly()
        fired = int(ready.value) == 1
        await RisingEdge(clk)
        if fired:
            break
    valid.value = 0


async def _idle(clk, rng, max_delay):
    for _ in range(rng.randint(0, max_delay) if max_delay else 0):
        await RisingEdge(clk)


class AxiLite:
    """AXI4-Lite master. With max_delay > 0 every channel is delayed by a
    random number of cycles, so AW and W arrive in either order."""

    def __init__(self, dut, rng, max_delay=0):
        self.dut, self.clk, self.rng, self.max_delay = dut, dut.aclk, rng, max_delay
        for name in ("awvalid", "wvalid", "bready", "arvalid", "rready"):
            getattr(dut, f"s_axi_{name}").value = 0

    async def _channel(self, valid, ready):
        await _idle(self.clk, self.rng, self.max_delay)
        await _handshake(self.clk, valid, ready)

    async def write(self, addr, data, strb=0xF):
        d = self.dut
        d.s_axi_awaddr.value = addr
        d.s_axi_wdata.value = data & 0xFFFFFFFF
        d.s_axi_wstrb.value = strb
        aw = cocotb.start_soon(self._channel(d.s_axi_awvalid, d.s_axi_awready))
        w = cocotb.start_soon(self._channel(d.s_axi_wvalid, d.s_axi_wready))
        await aw
        await w
        # The slave is the source of B, so here "ready" is ours and "valid" its.
        await _idle(self.clk, self.rng, self.max_delay)
        await _handshake(self.clk, d.s_axi_bready, d.s_axi_bvalid)

    async def read(self, addr):
        d = self.dut
        d.s_axi_araddr.value = addr
        await self._channel(d.s_axi_arvalid, d.s_axi_arready)
        await _idle(self.clk, self.rng, self.max_delay)
        d.s_axi_rready.value = 1
        while True:
            await ReadOnly()
            fired = int(d.s_axi_rvalid.value) == 1
            data = int(d.s_axi_rdata.value) if fired else 0
            await RisingEdge(self.clk)
            if fired:
                break
        d.s_axi_rready.value = 0
        return data


async def stream_send(dut, values, rng, p_valid=1.0):
    """Send elements on s_axis, with garbage on TDATA while TVALID is low."""
    for v in values:
        while rng.random() >= p_valid:
            dut.s_axis_tvalid.value = 0
            dut.s_axis_tdata.value = rng.getrandbits(32)
            await RisingEdge(dut.aclk)
        dut.s_axis_tdata.value = int(v) & 0xFFFFFFFF
        await _handshake(dut.aclk, dut.s_axis_tvalid, dut.s_axis_tready)
    dut.s_axis_tdata.value = rng.getrandbits(32)


async def stream_recv(dut, rng, p_ready=1.0, limit=None):
    """Receive signed elements from m_axis up to and including TLAST."""
    out = []
    while True:
        dut.m_axis_tready.value = 1 if rng.random() < p_ready else 0
        await ReadOnly()
        fired = int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value)
        if fired:
            word = int(dut.m_axis_tdata.value)
            out.append(word - (1 << 32) if word & (1 << 31) else word)
            last = int(dut.m_axis_tlast.value)
        await RisingEdge(dut.aclk)
        if fired and (last or (limit is not None and len(out) >= limit)):
            break
    dut.m_axis_tready.value = 0
    return out


class Host:
    def __init__(self, dut, rng, p_valid=1.0, p_ready=1.0, axil_delay=0):
        self.dut, self.rng = dut, rng
        self.p_valid, self.p_ready = p_valid, p_ready
        self.axil = AxiLite(dut, rng, axil_delay)
        self.rows = int(dut.ROWS.value)
        self.cols = int(dut.COLS.value)

    async def status(self):
        return await self.axil.read(REG_STATUS)

    async def set_dims(self, m, k, n, bias_en=False):
        await self.axil.write(REG_DIM_M, m)
        await self.axil.write(REG_DIM_K, k)
        await self.axil.write(REG_DIM_N, n)
        await self.axil.write(REG_CFG, int(bias_en))

    async def load(self, ctrl_bit, values):
        """Request a load, then stream the elements in row-major order."""
        await self.axil.write(REG_CTRL, ctrl_bit)
        await stream_send(self.dut, values, self.rng, self.p_valid)
        while (await self.status()) & ST_LOADING:
            pass

    async def load_a(self, a):
        await self.load(CTRL_LOAD_A, a.flatten())

    async def load_b(self, b):
        await self.load(CTRL_LOAD_B, b.flatten())

    async def load_bias(self, bias):
        await self.load(CTRL_LOAD_BIAS, bias.flatten())

    async def run(self, m, n):
        """START, collect the result stream, return (C, cycles)."""
        sink = cocotb.start_soon(stream_recv(self.dut, self.rng, self.p_ready))
        await self.axil.write(REG_CTRL, CTRL_START)
        flat = await sink
        assert len(flat) == m * n, f"got {len(flat)} result elements, expected {m * n}"
        st = await self.status()
        assert st & ST_DONE and not st & ST_BUSY, f"STATUS after run: {st:#x}"
        assert int(self.dut.irq_o.value) == 1
        return untile(flat, m, n, self.rows, self.cols), await self.axil.read(REG_CYCLES)

    async def gemm(self, a, b, bias=None):
        """Complete sequence for one multiplication."""
        m, k = a.shape
        n = b.shape[1]
        await self.set_dims(m, k, n, bias is not None)
        await self.load_a(a)
        await self.load_b(b)
        if bias is not None:
            await self.load_bias(bias)
        return await self.run(m, n)
