// -----------------------------------------------------------------------------
// gemm_mem: simple dual-port RAM whose word is LANES elements wide.
//
//   write: one element (lane) of one word per cycle
//   read : a whole word, registered, with read enable (the output holds its
//          value while re_i is low)
//
// A word holds everything the array needs in one cycle (a column segment of A
// or a row segment of B), so operands can be fed at one beat per cycle. Written
// in the byte-write-enable style that FPGA tools map onto block RAM.
// -----------------------------------------------------------------------------
module gemm_mem #(
    parameter int LANES  = 8,
    parameter int LANE_W = 8,
    parameter int DEPTH  = 1024,
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

    logic [LANES*LANE_W-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        for (int l = 0; l < LANES; l++) begin
            if (we_i && wlane_i == LW'(l)) mem[waddr_i][l*LANE_W +: LANE_W] <= wdata_i;
        end
    end

    always_ff @(posedge clk) begin
        if (re_i) rdata_o <= mem[raddr_i];
    end

endmodule
