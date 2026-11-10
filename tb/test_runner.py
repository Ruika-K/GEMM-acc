"""pytest entry point: builds and runs the cocotb tests for several parameter sets.

    pytest tb/ -v
"""

from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
SIM = "icarus"

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


@pytest.mark.parametrize("rows,cols,pipe", ARRAY_CONFIGS)
def test_gemm_array(rows, cols, pipe):
    build_dir = ROOT / "sim_build" / f"gemm_array_r{rows}_c{cols}_p{pipe}"
    runner = get_runner(SIM)
    runner.build(
        sources=[RTL / "gemm_pe.sv", RTL / "gemm_array.sv"],
        hdl_toplevel="gemm_array",
        parameters={"ROWS": rows, "COLS": cols, "PE_PIPE": pipe},
        timescale=("1ns", "1ps"),
        build_dir=build_dir,
        always=True,
    )
    runner.test(
        hdl_toplevel="gemm_array",
        test_module="test_gemm_array",
        test_dir=Path(__file__).resolve().parent,
        build_dir=build_dir,
    )
