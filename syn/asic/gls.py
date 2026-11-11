#!/usr/bin/env python3
"""Gate-level simulation: run the array testbench on a synthesised netlist.

    python3 syn/asic/run.py sys_4
    python3 syn/asic/gls.py sys_4          # netlist after synthesis
    python3 syn/asic/pnr.py sys_4
    python3 syn/asic/gls.py sys_4 --pnr    # netlist after place and route

With --pnr the netlist written after place and route is used: it additionally
contains the clock tree, the buffers inserted for timing and hold repair, and
every cell that was resized on the way.

The netlist of syn/build/asic/<job>/ is simulated with the functional Verilog
models of the sky130 standard cells and driven by tb/test_gemm_array.py, the
same testbench that checks the RTL. It answers one question: does the logic
that came out of synthesis still compute the same thing? Cell delays are not
simulated (functional models, no SDF).

The testbench changes its inputs exactly on the clock edge. RTL tolerates
that; a zero-delay netlist does not, because an input can race the clock
through combinational logic to a flip-flop. The netlist is therefore wrapped
in a small module that delays every input by 100 ps. The wrapper also carries
the parameters the testbench reads, which a netlist no longer has, and the
testbench samples outputs 200 ps after the edge (TB_SETTLE_PS) so that outputs
which depend combinationally on an input have settled.

Only the systolic array jobs (sys_N...) are supported.
"""

import os
import re
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[2]
PDK = Path(os.environ.get("PDK_ROOT", Path.home() / "pdk" / "sky130")) / "sky130A"
CELLS = PDK / "libs.ref" / "sky130_fd_sc_hd" / "verilog"

WRAPPER = """`timescale 1ns/1ps
module gemm_array_gls #(
    parameter DATA_W  = 8,
    parameter ACC_W   = 32,
    parameter ROWS    = {n},
    parameter COLS    = {n},
    parameter PE_PIPE = {pipe}
) (
    input                    clk,
    input                    rst_n,
    input  [ROWS-1:0]        a_valid_i,
    input  [ROWS*DATA_W-1:0] a_i,
    input  [COLS*DATA_W-1:0] b_i,
    input                    shift_i,
    input  [COLS*ACC_W-1:0]  c_i,
    output [COLS-1:0]        c_valid_o,
    output [COLS*ACC_W-1:0]  c_o
);
    // Inputs reach the netlist 100 ps after the clock edge that changed them.
    wire                   #0.1 rst_n_d     = rst_n;
    wire [ROWS-1:0]        #0.1 a_valid_d   = a_valid_i;
    wire [ROWS*DATA_W-1:0] #0.1 a_d         = a_i;
    wire [COLS*DATA_W-1:0] #0.1 b_d         = b_i;
    wire                   #0.1 shift_d     = shift_i;
    wire [COLS*ACC_W-1:0]  #0.1 c_d         = c_i;

    gemm_array u_netlist (
        .clk      (clk),
        .rst_n    (rst_n_d),
        .a_valid_i(a_valid_d),
        .a_i      (a_d),
        .b_i      (b_d),
        .shift_i  (shift_d),
        .c_i      (c_d),
        .c_valid_o(c_valid_o),
        .c_o      (c_o)
    );
endmodule
"""


def main():
    args = [a for a in sys.argv[1:] if a != "--pnr"]
    post_layout = "--pnr" in sys.argv[1:]
    job = args[0] if args else "sys_4"
    m = re.fullmatch(r"sys_(\d+)(_nopipe)?(_ripple)?", job)
    if not m:
        sys.exit("only sys_N jobs are supported")
    netlist = ROOT / "syn" / "build" / "asic" / job / "netlist.v"
    if post_layout:
        netlist = netlist.parent / "pnr" / "gemm_array.pnr.v"
    if not netlist.exists():
        step = "pnr.py" if post_layout else "run.py"
        sys.exit(f"{netlist} not found: run syn/asic/{step} {job} first")

    build = ROOT / "sim_build" / f"gls_{job}{'_pnr' if post_layout else ''}"
    build.mkdir(parents=True, exist_ok=True)
    wrapper = build / "gemm_array_gls.v"
    wrapper.write_text(WRAPPER.format(n=m.group(1), pipe=0 if m.group(2) else 1))

    runner = get_runner("icarus")
    runner.build(
        sources=[CELLS / "primitives.v", CELLS / "sky130_fd_sc_hd.v", netlist, wrapper],
        hdl_toplevel="gemm_array_gls",
        defines={"FUNCTIONAL": 1, "UNIT_DELAY": ""},
        timescale=("1ns", "1ps"),
        build_dir=build,
        always=True,
    )
    os.environ["TB_SETTLE_PS"] = "200"
    runner.test(
        hdl_toplevel="gemm_array_gls",
        test_module="test_gemm_array",
        test_dir=ROOT / "tb",
        build_dir=build,
    )


if __name__ == "__main__":
    main()
