#!/usr/bin/env python3
"""Gate-level simulation: run the array testbench on a synthesised netlist.

    python3 syn/asic/run.py sys_4
    python3 syn/asic/gls.py sys_4          # netlist after synthesis
    python3 syn/asic/pnr.py sys_4
    python3 syn/asic/gls.py sys_4 --pnr    # netlist after place and route
    python3 syn/asic/pnr.py pe_m4_macro sys_8_m4_hier
    python3 syn/asic/gls.py sys_8_m4 --hier  # after hierarchical place and route
    python3 syn/asic/gls.py chip_8_m4        # the routed chip, with SRAM models

With --pnr the netlist written after place and route is used: it additionally
contains the clock tree, the buffers inserted for timing and hold repair, and
every cell that was resized on the way. With --hier it is the top level of the
hierarchical flow together with the routed netlist of the PE macro.

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

Only the systolic array jobs (sys_N, sys_N_sM, sys_N_mM, ...) are supported.
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
    parameter PE_PIPE = {pipe},
    parameter ACC_SEG = {seg},
    parameter MUL_CS  = {mul},
    parameter CPA_SEG = {cpa}
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


CHIP_WRAPPER = """`timescale 1ns/1ps
module gemm_top_gls #(
    parameter DATA_W     = 8,
    parameter ACC_W      = 32,
    parameter ROWS       = 8,
    parameter COLS       = 8,
    parameter PE_PIPE    = 1,
    parameter K_MAX      = 1024,
    parameter OUT_DEPTH  = 8,
    parameter A_DEPTH    = 1024,
    parameter B_DEPTH    = 1024,
    parameter BIAS_DEPTH = 64,
    parameter ACC_SEG    = {seg},
    parameter MUL_CS     = {mul},
    parameter CPA_SEG    = {cpa}
) (
    input         aclk,
    input         aresetn,
    input         s_axi_awvalid,
    output        s_axi_awready,
    input  [7:0]  s_axi_awaddr,
    input         s_axi_wvalid,
    output        s_axi_wready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    output        s_axi_bvalid,
    input         s_axi_bready,
    output [1:0]  s_axi_bresp,
    input         s_axi_arvalid,
    output        s_axi_arready,
    input  [7:0]  s_axi_araddr,
    output        s_axi_rvalid,
    input         s_axi_rready,
    output [31:0] s_axi_rdata,
    output [1:0]  s_axi_rresp,
    input         s_axis_tvalid,
    output        s_axis_tready,
    input  [31:0] s_axis_tdata,
    output        m_axis_tvalid,
    input         m_axis_tready,
    output [31:0] m_axis_tdata,
    output        m_axis_tlast,
    output        irq_o
);
    // Inputs reach the netlist 100 ps after the clock edge that changed them
    // (see WRAPPER). Every output of gemm_top comes from registers, so the
    // test bench can sample them as it does for the RTL. The delayed copies
    // start at 0 (reset asserted): the test bench's clock has an edge at time
    // 0, and an X captured there stays X in registers whose next value
    // depends on themselves (the netlist cannot see that the X is masked).
    reg        aresetn_d = 1'b0;
    reg        awvalid_d = 1'b0, wvalid_d = 1'b0, bready_d = 1'b0, arvalid_d = 1'b0;
    reg        rready_d = 1'b0, s_tvalid_d = 1'b0, m_tready_d = 1'b0;
    reg [7:0]  awaddr_d = 8'd0, araddr_d = 8'd0;
    reg [31:0] wdata_d = 32'd0, s_tdata_d = 32'd0;
    reg [3:0]  wstrb_d = 4'd0;
    always @(aresetn)       aresetn_d  <= #0.1 aresetn;
    always @(s_axi_awvalid) awvalid_d  <= #0.1 s_axi_awvalid;
    always @(s_axi_awaddr)  awaddr_d   <= #0.1 s_axi_awaddr;
    always @(s_axi_wvalid)  wvalid_d   <= #0.1 s_axi_wvalid;
    always @(s_axi_wdata)   wdata_d    <= #0.1 s_axi_wdata;
    always @(s_axi_wstrb)   wstrb_d    <= #0.1 s_axi_wstrb;
    always @(s_axi_bready)  bready_d   <= #0.1 s_axi_bready;
    always @(s_axi_arvalid) arvalid_d  <= #0.1 s_axi_arvalid;
    always @(s_axi_araddr)  araddr_d   <= #0.1 s_axi_araddr;
    always @(s_axi_rready)  rready_d   <= #0.1 s_axi_rready;
    always @(s_axis_tvalid) s_tvalid_d <= #0.1 s_axis_tvalid;
    always @(s_axis_tdata)  s_tdata_d  <= #0.1 s_axis_tdata;
    always @(m_axis_tready) m_tready_d <= #0.1 m_axis_tready;

    gemm_top u_netlist (
        .aclk(aclk), .aresetn(aresetn_d),
        .s_axi_awvalid(awvalid_d), .s_axi_awready(s_axi_awready), .s_axi_awaddr(awaddr_d),
        .s_axi_wvalid(wvalid_d), .s_axi_wready(s_axi_wready), .s_axi_wdata(wdata_d),
        .s_axi_wstrb(wstrb_d), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(bready_d),
        .s_axi_bresp(s_axi_bresp), .s_axi_arvalid(arvalid_d), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(araddr_d), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(rready_d),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axis_tvalid(s_tvalid_d), .s_axis_tready(s_axis_tready), .s_axis_tdata(s_tdata_d),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_tready_d), .m_axis_tdata(m_axis_tdata),
        .m_axis_tlast(m_axis_tlast), .irq_o(irq_o)
    );
endmodule
"""


def primitives(build, init):
    """The cell library's primitives with every flip-flop and latch starting
    at `init` instead of X.

    Registers that the RTL does not reset start at X in simulation. The RTL
    simulation is optimistic about X and runs; the netlist is not: for
    example, the loader clears base_q while idle through logic that also
    reads stride_q, which nothing resets, and an X on stride_q left base_q X
    although the result is 0 for any value of stride_q. Hardware powers up
    with some value in every register, so the chip is simulated twice, with
    all registers starting at 0 and at 1.
    """
    text = (CELLS / "primitives.v").read_text()
    text = re.sub(r"(primitive sky130_fd_sc_hd__udp_(?:dff|dlatch)\S*.*?\n\s*reg Q;)",
                  rf"\1\n    initial Q = 1'b{init};", text, flags=re.S)
    path = build / "primitives.v"
    path.write_text(text)
    return path


def chip(job, init):
    """Gate-level simulation of the routed chip: top-level netlist, PE macro
    netlist and the OpenRAM simulation models of the SRAM macros, driven by
    tb/test_gemm_top.py (default parameters: 8 x 8, 1024-word memories)."""
    variant = job[len("chip_8"):]
    asic = ROOT / "syn" / "build" / "asic"
    netlists = [asic / job / "pnr" / "gemm_top.pnr.v", asic / f"pe{variant}" / "macro" / "gemm_pe.pnr.v"]
    for netlist in netlists:
        if not netlist.exists():
            sys.exit(f"{netlist} not found: run syn/asic/pnr.py pe{variant}_macro {job} first")
    build = ROOT / "sim_build" / f"gls_{job}_pnr_init{init}"
    build.mkdir(parents=True, exist_ok=True)
    m = re.fullmatch(r"(?:_([sm])(\d+))?", variant)
    (build / "gemm_top_gls.v").write_text(
        CHIP_WRAPPER.replace("{seg}", m.group(2) or "0").replace("{mul}", "1" if m.group(1) == "m" else "0")
        .replace("{cpa}", "8" if m.group(1) == "m" else "16"))
    # The models print every access unless VERBOSE is 0; the netlist cannot
    # set it, so the copies here do.
    models = []
    for name in ("sky130_sram_1kbyte_1rw1r_32x256_8", "sky130_sram_2kbyte_1rw1r_32x512_8"):
        src = PDK / "libs.ref" / "sky130_sram_macros" / "verilog" / f"{name}.v"
        dst = build / src.name
        dst.write_text(re.sub(r"parameter VERBOSE = 1", "parameter VERBOSE = 0", src.read_text()))
        models.append(dst)
    runner = get_runner("icarus")
    runner.build(
        sources=[primitives(build, init), CELLS / "sky130_fd_sc_hd.v", *netlists, *models,
                 build / "gemm_top_gls.v"],
        hdl_toplevel="gemm_top_gls",
        # Flip-flops and latches (the only cells that use UNIT_DELAY) change
        # their output 50 ps after the clock edge; all other cells have no
        # delay. Without it, a clock tree is a chain of zero-delay buffers and
        # a register whose clock passes fewer buffers than the next one's
        # changes its output before the next one samples: the hand-built PE
        # tree has 6 buffers to a flip-flop, the register tree 8 - 10.
        defines={"FUNCTIONAL": 1, "UNIT_DELAY": "#0.05"},
        timescale=("1ns", "1ps"),
        build_dir=build,
        always=True,
    )
    runner.test(hdl_toplevel="gemm_top_gls", test_module="test_gemm_top",
                test_dir=ROOT / "tb", build_dir=build)


def main():
    if sys.argv[1:] and sys.argv[1].startswith("chip_"):
        for init in (0, 1):
            chip(sys.argv[1], init)
        return
    args = [a for a in sys.argv[1:] if a not in ("--pnr", "--hier")]
    post_layout = "--pnr" in sys.argv[1:]
    hier = "--hier" in sys.argv[1:]
    job = args[0] if args else "sys_4"
    m = re.fullmatch(r"sys_(\d+)(_nopipe)?(_ripple)?(?:_([sm])(\d+))?", job)
    if not m:
        sys.exit("only sys_N jobs are supported")
    build_dir = ROOT / "syn" / "build" / "asic"
    netlists = [build_dir / job / "netlist.v"]
    step = "run.py"
    if post_layout:
        netlists = [build_dir / job / "pnr" / "gemm_array.pnr.v"]
        step = "pnr.py"
    if hier:
        variant = job[job.index("_", 4):] if job.count("_") > 1 else ""
        netlists = [build_dir / job / "pnr_hier" / "gemm_array.pnr.v",
                    build_dir / f"pe{variant}" / "macro" / "gemm_pe.pnr.v"]
        step = "pnr.py"
    for netlist in netlists:
        if not netlist.exists():
            sys.exit(f"{netlist} not found: run syn/asic/{step} first")

    tag = "_pnr" if post_layout else "_hier" if hier else ""
    build = ROOT / "sim_build" / f"gls_{job}{tag}"
    build.mkdir(parents=True, exist_ok=True)
    wrapper = build / "gemm_array_gls.v"
    wrapper.write_text(WRAPPER.format(n=m.group(1), pipe=0 if m.group(2) else 1,
                                      seg=m.group(5) or 0, mul=1 if m.group(4) == "m" else 0,
                                      cpa=8 if m.group(4) == "m" else 16))

    runner = get_runner("icarus")
    runner.build(
        sources=[CELLS / "primitives.v", CELLS / "sky130_fd_sc_hd.v", *netlists, wrapper],
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
