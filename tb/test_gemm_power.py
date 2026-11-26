"""Workloads for power analysis of the routed chip (syn/asic/power.py).

Each test drives one workload and raises `dump_on` in the gate-level wrapper
(syn/asic/gls.py) where the window to be measured starts; the window ends
with the simulation, at the end of the test. The switching activity in that
window is what OpenSTA turns into power.

    compute   a 32 x 72 x 32 multiplication with random int8 operands and
              bias (16 full tiles, the run of test_gemm_top.throughput):
              from START until the last result has been read and checked
    idle      the clock running, nothing to do: 1000 cycles after reset

The clock period is that of the timing constraints (5 ns), so the power is
the power at 200 MHz.
"""

import json
import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.utils import get_sim_time

from gemm_host import Host
from test_gemm_top import TopParams, operands, reference

CLK_NS = float(os.environ.get("POWER_CLK_NS", "5"))
SEED = int(os.environ.get("TB_SEED", "1"))


async def setup(dut, seed):
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    dut.aresetn.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.m_axis_tready.value = 0
    rng = random.Random(seed)
    host = Host(dut, rng)
    for _ in range(3):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    return TopParams(dut), rng, host


def window_start(dut):
    dut.dump_on.value = 1
    return get_sim_time("ns")


def window_end(dut, name, t0, **info):
    """Record the window for power.py next to the VCD file: its length in ns
    and what was done in it."""
    info = dict(workload=name, window_ns=get_sim_time("ns") - t0, clk_ns=CLK_NS, **info)
    dut._log.info("POWER %s", info)
    vcd = cocotb.plusargs.get("vcd")
    if vcd:
        with open(f"{vcd}.json", "w") as f:
            json.dump(info, f)


@cocotb.test()
async def compute(dut):
    p, rng, host = await setup(dut, SEED + 10)
    m, k, n = 4 * p.rows, p.rows * p.cols + 8, 4 * p.cols
    a, b, bias = operands(p, rng, m, k, n)
    await host.set_dims(m, k, n, True)
    await host.load_a(a)
    await host.load_b(b)
    await host.load_bias(bias)
    await RisingEdge(dut.aclk)
    t0 = window_start(dut)
    got, cycles = await host.run(m, n)
    assert np.array_equal(got, reference(a, b, bias)), "wrong result"
    window_end(dut, "compute", t0, macs=m * k * n, run_cycles=cycles)


@cocotb.test()
async def idle(dut):
    _, _, _ = await setup(dut, SEED)
    await ClockCycles(dut.aclk, 10)
    t0 = window_start(dut)
    await ClockCycles(dut.aclk, 1000)
    window_end(dut, "idle", t0, macs=0, run_cycles=0)
