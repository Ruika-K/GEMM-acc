// Black-box stand-in for gemm_mem during ASIC synthesis. The operand memories
// are SRAM macros in an ASIC, not standard cells, so the logic synthesis flow
// leaves them out and reports their size separately.
(* blackbox *)
module gemm_mem #(
    parameter int LANES  = 8,
    parameter int LANE_W = 8,
    parameter int DEPTH  = 1024,
    parameter int SPLIT  = 0,
    localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1
) (
    input  logic                    clk,
    input  logic                    we_i,
    input  logic [AW-1:0]           waddr_i,
    input  logic [LW-1:0]           wlane_i,
    input  logic [LANE_W-1:0]       wdata_i,
    input  logic                    re_i,
    input  logic [AW-1:0]           raddr_i,
    output logic [LANES*LANE_W-1:0] rdata_o
);
endmodule
