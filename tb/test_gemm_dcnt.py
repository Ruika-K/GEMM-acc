"""cocotb test for gemm_dcnt, the down-counter that reports when it reaches 1.

The counter keeps its high half as "high half - 1" and a set of flags worked
out one decrement ahead, so the interesting cases are where the low half
wraps: values around multiples of 2^(W/2), and the largest value. The array
and top-level tests never count that far (their dimensions are small), so the
counter is checked on its own: load, decrement with random gaps, reload at
random points, against a plain integer model, every cycle.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

SEED = int(os.environ.get("TB_SEED", "1"))


class Model:
    def __init__(self):
        self.value = None
        self.init = None

    def step(self, load, value, reload, dec):
        if load:
            self.value = value
            self.init = value
        elif reload:
            self.value = self.init
        elif dec:
            assert self.value > 1, "test bench decremented at 1"
            self.value -= 1


async def drive(dut, model, load=0, value=0, reload=0, dec=0):
    """Apply inputs for one cycle and check last_o after the edge."""
    dut.load_i.value = load
    dut.value_i.value = value
    dut.reload_i.value = reload
    dut.dec_i.value = dec
    await RisingEdge(dut.clk)
    model.step(load, value, reload, dec)
    await ReadOnly()
    got = int(dut.last_o.value)
    want = int(model.value == 1)
    assert got == want, f"value {model.value}: last_o = {got}, expected {want}"
    await Timer(1, "ns")     # leave the read-only phase before inputs change


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.load_i.value = 0
    dut.reload_i.value = 0
    dut.dec_i.value = 0
    dut.value_i.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, "ns")
    w = int(dut.W.value)
    return 1 << ((w + 1) // 2), (1 << w) - 1


async def count_down(dut, model, rng, value, reload_chance, idle_chance=0.2):
    """Load value and decrement to 1, with idle cycles and occasional reloads."""
    await drive(dut, model, load=1, value=value)
    reloads = 0
    while model.value > 1:
        if reloads < 2 and rng.random() < reload_chance:
            reloads += 1
            await drive(dut, model, reload=1)
        elif rng.random() < idle_chance:
            await drive(dut, model)
        else:
            await drive(dut, model, dec=1)
    # Stays at 1 while not decremented.
    await drive(dut, model)
    await drive(dut, model)


@cocotb.test()
async def boundaries_and_random(dut):
    half, top = await setup(dut)
    rng = random.Random(SEED)
    model = Model()
    if top < 64:
        values = list(range(1, top + 1))          # every value
    else:
        values = [1, 2, 3, half - 1, half, half + 1, half + 2, 2 * half - 1, 2 * half,
                  2 * half + 1, 3 * half, top - 1, top]
        values += [rng.randrange(1, top + 1) for _ in range(6)]
    for v in values:
        await count_down(dut, model, rng, v, reload_chance=0.002 if v > 64 else 0.05)


@cocotb.test()
async def reload_restarts(dut):
    """Reload right after the low half wrapped, and load against reload."""
    half, top = await setup(dut)
    rng = random.Random(SEED + 1)
    model = Model()
    # A row of one element: the counter restarts at 1 every time.
    await drive(dut, model, load=1, value=1)
    for _ in range(3):
        await drive(dut, model, reload=1)
    for v in sorted({min(top, x) for x in (2, half + 1, 2 * half + 3, top)}):
        await drive(dut, model, load=1, value=v)
        for _ in range(2):
            # Down to just below the last wrap of the low half (or to 1), reload.
            target = v - (v % half) - 1 if v > half else 1
            while model.value > max(1, target):
                await drive(dut, model, dec=1)
            await drive(dut, model, reload=1)
        # Load, reload and decrement in the same cycle: load wins, then reload.
        await drive(dut, model, load=1, value=rng.randrange(2, top + 1), reload=1, dec=1)
        await drive(dut, model, reload=1, dec=1)
