"""Helpers shared by the cocotb testbenches."""

import numpy as np


def pack(values, width):
    """Pack a list of signed ints into one flat vector, element 0 at the LSB."""
    mask = (1 << width) - 1
    word = 0
    for idx, v in enumerate(values):
        word |= (v & mask) << (idx * width)
    return word


def to_signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def random_matrix(rng, shape, width, mode="random"):
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if mode == "min":
        return np.full(shape, lo, dtype=np.int64)
    if mode == "max":
        return np.full(shape, hi, dtype=np.int64)
    return np.array(
        [[rng.randint(lo, hi) for _ in range(shape[1])] for _ in range(shape[0])],
        dtype=np.int64,
    )


def cpa_latency(dut):
    """Cycles the final adders add to the array outputs (0 without saved carries)."""
    seg, acc_w = int(dut.ACC_SEG.value), int(dut.ACC_W.value)
    if seg == 0 or seg >= acc_w:
        return 0
    return -(-acc_w // int(dut.CPA_SEG.value))
