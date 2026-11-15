"""cocotb test for the multiply-accumulate datapath (gemm_mac, gemm_mac_cs).

Every one of the 2^(2*DATA_W) operand pairs is multiplied and accumulated, and
the accumulator is compared with a running sum after every cycle. The array
tests use random operands; a multiplier written by hand deserves all of them.

The accumulator may be in saved-carry form: c_o is {saved carries, sum}, and
its value is the sum plus each carry at the bit where its segment starts.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from util import to_signed

SEED = int(os.environ.get("TB_SEED", "1"))


class Mac:
    def __init__(self, dut):
        self.dut = dut
        self.data_w = int(dut.DATA_W.value)
        self.acc_w = int(dut.ACC_W.value)
        self.pipe = int(dut.PE_PIPE.value)
        seg = int(dut.ACC_SEG.value)
        self.seg = seg if 0 < seg < self.acc_w else 0
        self.mask = (1 << self.acc_w) - 1

    def value(self):
        """Accumulator contents as an unsigned ACC_W-bit number."""
        raw = int(self.dut.c_o.value)
        total = raw & self.mask
        carries = raw >> self.acc_w
        s = 1
        while carries:
            if carries & 1:
                total += 1 << (s * self.seg)
            carries >>= 1
            s += 1
        return total & self.mask


@cocotb.test()
async def all_operand_pairs(dut):
    m = Mac(dut)
    rng = random.Random(SEED)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    n = 1 << m.data_w
    pairs = [(a, b) for a in range(n) for b in range(n)]
    rng.shuffle(pairs)

    # One entry per cycle: operands, whether they count, and an optional load.
    plan = []
    start = rng.getrandbits(m.acc_w)
    plan.append(dict(load=start))
    for idx, (a, b) in enumerate(pairs):
        if rng.random() < 0.02:                       # bubble: operands must be ignored
            plan.append(dict(a=rng.randrange(n), b=rng.randrange(n), valid=0))
        if idx == len(pairs) // 2:                    # reload in the middle of the run
            plan.append(dict(load=rng.getrandbits(m.acc_w)))
        plan.append(dict(a=a, b=b, valid=1))
    plan += [dict()] * (m.pipe + 2)

    dut.mac_valid_i.value = 0
    dut.acc_shift_i.value = 0
    dut.a_i.value = 0
    dut.b_i.value = 0
    dut.c_i.value = 0
    await RisingEdge(dut.clk)

    expect = None          # accumulator after the edge that ends the current cycle
    checked = 0
    for cyc, step in enumerate(plan):
        # Operands are presented PE_PIPE cycles before the controls of their
        # accumulate cycle, as gemm_pe does.
        ahead = plan[cyc + m.pipe] if cyc + m.pipe < len(plan) else {}
        dut.a_i.value = ahead.get("a", rng.randrange(n))
        dut.b_i.value = ahead.get("b", rng.randrange(n))
        dut.mac_valid_i.value = step.get("valid", 0)
        dut.acc_shift_i.value = 1 if "load" in step else 0
        dut.c_i.value = step.get("load", rng.getrandbits(m.acc_w))

        await ReadOnly()
        if expect is not None:
            got = m.value()
            assert got == expect, (
                f"cycle {cyc}: accumulator {got:#x}, expected {expect:#x}")
            checked += 1

        if "load" in step:
            expect = step["load"]
        elif step.get("valid", 0):
            prod = to_signed(step["a"], m.data_w) * to_signed(step["b"], m.data_w)
            expect = (expect + prod) & m.mask
        await RisingEdge(dut.clk)

    assert checked >= len(pairs)
    dut._log.info("%d operand pairs, %d cycles checked", len(pairs), checked)
