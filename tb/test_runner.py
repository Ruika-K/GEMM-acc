"""pytest entry point: builds and runs the cocotb tests for several parameter sets.

    pytest tb/ -v
"""

from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
TB = Path(__file__).resolve().parent
SIM = "icarus"

MAC_SOURCES = [RTL / "gemm_mac.sv", RTL / "gemm_mac_cs.sv", RTL / "gemm_cpa.sv"]
ARRAY_SOURCES = MAC_SOURCES + [RTL / "gemm_pe.sv", RTL / "gemm_array.sv"]
CORE_SOURCES = ARRAY_SOURCES + [
    RTL / "gemm_delay.sv",
    RTL / "gemm_fifo.sv",
    RTL / "gemm_ctrl.sv",
    RTL / "gemm_core.sv",
]

TOP_SOURCES = CORE_SOURCES + [
    RTL / "gemm_mem.sv",
    RTL / "gemm_tile_iter.sv",
    RTL / "gemm_load.sv",
    RTL / "gemm_seq.sv",
    RTL / "gemm_out.sv",
    RTL / "gemm_csr.sv",
    RTL / "gemm_top.sv",
]

ARRAY_CONFIGS = [
    # rows, cols, pe_pipe, acc_seg, cpa_seg
    (4, 4, 1, 0, 16),
    (4, 4, 0, 0, 16),
    (8, 8, 1, 0, 16),
    (8, 8, 0, 0, 16),
    (3, 5, 1, 0, 16),
    (5, 2, 0, 0, 16),
    (1, 1, 1, 0, 16),
    # saved carries in the accumulator
    (4, 4, 1, 1, 16),    # full carry-save
    (8, 8, 1, 8, 16),
    (4, 4, 0, 16, 16),
    (3, 5, 1, 12, 12),   # uneven segments, final adder in three stages
    (5, 2, 0, 1, 32),    # final adder in one stage
    (2, 3, 1, 4, 8),
    (1, 1, 1, 8, 8),
    (2, 2, 1, 32, 16),   # one segment: same as the plain adder
]

# Multiplier without a final adder (MUL_CS = 1): rows, cols, pe_pipe, acc_seg
ARRAY_MULCS_CONFIGS = [
    (4, 4, 1, 4),
    (8, 8, 1, 4),
    (4, 4, 1, 0),    # plain adder after the compressor
    (3, 5, 1, 1),
    (5, 2, 0, 8),
    (1, 1, 1, 2),
]

CORE_CONFIGS = [
    # rows, cols, pe_pipe, out_depth
    (4, 4, 1, 4),
    (4, 4, 0, 4),
    (8, 8, 1, 8),
    (8, 8, 0, 8),
    (3, 5, 1, 2),   # FIFO smaller than a tile
    (5, 2, 0, 1),   # single-entry FIFO
    (2, 6, 1, 16),  # FIFO larger than a tile
    (1, 3, 0, 1),   # single row: no wait state
    (1, 1, 1, 1),
]

# The same core with saved carries: rows, cols, pe_pipe, out_depth, acc_seg
CORE_CS_CONFIGS = [
    (4, 4, 1, 4, 1),
    (8, 8, 1, 8, 8),
    (3, 5, 0, 2, 16),
    (1, 3, 1, 1, 4),
]


TOP_CONFIGS = [
    # rows, cols, pe_pipe, out_depth, mem_split
    (4, 4, 1, 4, 0),
    (8, 8, 1, 8, 0),
    (3, 5, 0, 3, 0),
    (5, 3, 1, 2, 0),   # output FIFO smaller than a tile
    (2, 2, 0, 2, 0),
    (1, 1, 1, 1, 0),
    (4, 4, 1, 4, 1),   # one RAM per lane
    (3, 5, 0, 3, 1),
]

# The same top level with saved carries: ..., mem_split, acc_seg
TOP_CS_CONFIGS = [
    (4, 4, 1, 4, 0, 1),
    (8, 8, 1, 8, 0, 8),
    (3, 5, 0, 3, 0, 16),
]


BCAST_CONFIGS = [
    # rows, cols, pe_pipe, acc_seg
    (4, 4, 1, 0),
    (3, 5, 0, 0),
    (1, 1, 1, 0),
    (4, 4, 1, 1),
    (3, 5, 0, 8),
    (2, 2, 1, 12),
]


def simulate(top, sources, test_module, parameters):
    tag = "_".join(f"{k.lower()}{v}" for k, v in parameters.items())
    build_dir = ROOT / "sim_build" / f"{top}_{tag}"
    runner = get_runner(SIM)
    runner.build(
        sources=sources,
        hdl_toplevel=top,
        parameters=parameters,
        timescale=("1ns", "1ps"),
        build_dir=build_dir,
        always=True,
    )
    runner.test(
        hdl_toplevel=top,
        test_module=test_module,
        test_dir=TB,
        build_dir=build_dir,
    )


MAC_CONFIGS = [
    # module, pe_pipe, acc_seg
    ("gemm_mac", 1, 0),
    ("gemm_mac", 0, 1),
    ("gemm_mac", 1, 8),
    ("gemm_mac_cs", 1, 0),
    ("gemm_mac_cs", 1, 1),
    ("gemm_mac_cs", 1, 4),
    ("gemm_mac_cs", 0, 8),
    ("gemm_mac_cs", 1, 12),
]


@pytest.mark.parametrize("module,pipe,acc_seg", MAC_CONFIGS)
def test_gemm_mac(module, pipe, acc_seg):
    """Every operand pair through the datapath, with and without saved carries."""
    simulate(module, MAC_SOURCES, "test_gemm_mac",
             {"PE_PIPE": pipe, "ACC_SEG": acc_seg})


@pytest.mark.parametrize("rows,cols,pipe,acc_seg,cpa_seg", ARRAY_CONFIGS)
def test_gemm_array(rows, cols, pipe, acc_seg, cpa_seg):
    simulate(
        "gemm_array",
        ARRAY_SOURCES,
        "test_gemm_array",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "ACC_SEG": acc_seg, "CPA_SEG": cpa_seg},
    )


@pytest.mark.parametrize("rows,cols,pipe,acc_seg", ARRAY_MULCS_CONFIGS)
def test_gemm_array_mul_cs(rows, cols, pipe, acc_seg):
    simulate(
        "gemm_array",
        ARRAY_SOURCES,
        "test_gemm_array",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "ACC_SEG": acc_seg, "MUL_CS": 1},
    )


def core_params(rows, cols, pipe, depth, cs, mul_cs=0):
    return {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "OUT_DEPTH": depth, "ACC_SEG": cs,
            "MUL_CS": mul_cs}


@pytest.mark.parametrize("rows,cols,pipe,depth", CORE_CONFIGS)
def test_gemm_core(rows, cols, pipe, depth):
    simulate("gemm_core", CORE_SOURCES, "test_gemm_core", core_params(rows, cols, pipe, depth, 0))


@pytest.mark.parametrize("rows,cols,pipe,depth,seg", CORE_CS_CONFIGS)
def test_gemm_core_carry_save(rows, cols, pipe, depth, seg):
    simulate("gemm_core", CORE_SOURCES, "test_gemm_core", core_params(rows, cols, pipe, depth, seg))


@pytest.mark.parametrize("rows,cols,pipe,depth,seg", [(4, 4, 1, 4, 4), (3, 5, 0, 2, 1)])
def test_gemm_core_mul_cs(rows, cols, pipe, depth, seg):
    simulate("gemm_core", CORE_SOURCES, "test_gemm_core",
             core_params(rows, cols, pipe, depth, seg, 1))


def top_params(rows, cols, pipe, depth, split, cs, mul_cs=0):
    return {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "OUT_DEPTH": depth,
            "MEM_SPLIT": split, "ACC_SEG": cs, "MUL_CS": mul_cs}


@pytest.mark.parametrize("rows,cols,pipe,depth,split", TOP_CONFIGS)
def test_gemm_top(rows, cols, pipe, depth, split):
    simulate("gemm_top", TOP_SOURCES, "test_gemm_top", top_params(rows, cols, pipe, depth, split, 0))


@pytest.mark.parametrize("rows,cols,pipe,depth,split,seg", TOP_CS_CONFIGS)
def test_gemm_top_carry_save(rows, cols, pipe, depth, split, seg):
    simulate("gemm_top", TOP_SOURCES, "test_gemm_top", top_params(rows, cols, pipe, depth, split, seg))


@pytest.mark.parametrize("rows,cols,pipe,depth,split,seg", [(4, 4, 1, 4, 0, 4), (8, 8, 1, 8, 0, 4)])
def test_gemm_top_mul_cs(rows, cols, pipe, depth, split, seg):
    simulate("gemm_top", TOP_SOURCES, "test_gemm_top",
             top_params(rows, cols, pipe, depth, split, seg, 1))


@pytest.mark.parametrize("rows,cols,pipe,cs,mul_cs", [c + (0,) for c in BCAST_CONFIGS]
                         + [(4, 4, 1, 4, 1), (3, 5, 0, 1, 1)])
def test_gemm_array_bcast(rows, cols, pipe, cs, mul_cs):
    """Baseline used only for the synthesis comparison."""
    simulate(
        "gemm_array_bcast",
        MAC_SOURCES + [ROOT / "syn" / "common" / "gemm_array_bcast.sv"],
        "test_gemm_array_bcast",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "ACC_SEG": cs, "MUL_CS": mul_cs},
    )
