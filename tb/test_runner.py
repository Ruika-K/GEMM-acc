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

ARRAY_SOURCES = [RTL / "gemm_pe.sv", RTL / "gemm_array.sv"]
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
    # rows, cols, pe_pipe
    (4, 4, 1),
    (4, 4, 0),
    (8, 8, 1),
    (8, 8, 0),
    (3, 5, 1),
    (5, 2, 0),
    (1, 1, 1),
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


TOP_CONFIGS = [
    # rows, cols, pe_pipe, out_depth
    (4, 4, 1, 4),
    (8, 8, 1, 8),
    (3, 5, 0, 3),
    (5, 3, 1, 2),   # output FIFO smaller than a tile
    (2, 2, 0, 2),
    (1, 1, 1, 1),
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


@pytest.mark.parametrize("rows,cols,pipe", ARRAY_CONFIGS)
def test_gemm_array(rows, cols, pipe):
    simulate(
        "gemm_array",
        ARRAY_SOURCES,
        "test_gemm_array",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe},
    )


@pytest.mark.parametrize("rows,cols,pipe,depth", CORE_CONFIGS)
def test_gemm_core(rows, cols, pipe, depth):
    simulate(
        "gemm_core",
        CORE_SOURCES,
        "test_gemm_core",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "OUT_DEPTH": depth},
    )


@pytest.mark.parametrize("rows,cols,pipe,depth", TOP_CONFIGS)
def test_gemm_top(rows, cols, pipe, depth):
    simulate(
        "gemm_top",
        TOP_SOURCES,
        "test_gemm_top",
        {"ROWS": rows, "COLS": cols, "PE_PIPE": pipe, "OUT_DEPTH": depth},
    )
