// -----------------------------------------------------------------------------
// gemm_mem for sky130: the operand memory built from OpenRAM SRAM macros
// (sky130_sram_macros), for synthesis and place and route of the complete
// chip. Same ports and behaviour as rtl/gemm_mem.sv: one write port that
// writes one lane of a word, one read port with a registered read, and the
// read data held while no read is issued.
//
// Macros (1rw1r: port 0 read/write, used for writing; port 1 read-only):
//
//   DEPTH <= 256   sky130_sram_1kbyte_1rw1r_32x256_8    32 bits x 256
//   DEPTH <= 1024  sky130_sram_2kbyte_1rw1r_32x512_8    32 bits x 512, stacked
//
// A word of LANES * LANE_W bits is spread over columns of 32-bit macros,
// 32 / LANE_W lanes per macro (LANE_W = 8, 16 or 32), each lane written
// through the byte mask. With the default parameters:
//
//   A, B   8 lanes x 8 bits x 1024 words   2 columns x 2 rows of 2 KB macros
//   bias   8 lanes x 32 bits x 64 words    8 columns of 1 KB macros
//
// Writes go through a register here: the loader drives the write ports of all
// three memories, which sit in three corners of the chip, and the wire to the
// farthest took more than a cycle at the slow corner. A write takes effect
// one cycle later than in gemm_mem.sv, which nothing notices: the memories
// are only read once loading has finished and the next run has been started
// over AXI4-Lite.
//
// The macros do not hold their read output: the model drives X from 1 ns
// after the clock edge until the next read completes, and the RTL relies on
// the word staying put (the bias word is used for every row of a tile). The
// output is therefore held here, in a register that takes the read data in
// the cycle after a read.
// -----------------------------------------------------------------------------
module gemm_mem #(
    parameter int LANES  = 8,
    parameter int LANE_W = 8,
    parameter int DEPTH  = 1024,
    /* verilator lint_off UNUSEDPARAM */
    parameter int SPLIT  = 0,           // no meaning for macros
    /* verilator lint_on UNUSEDPARAM */
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

    localparam int MACRO_W  = 32;
    localparam int PER      = MACRO_W / LANE_W;             // lanes per macro
    localparam int COLS_M   = (LANES + PER - 1) / PER;      // macro columns
    localparam bit SMALL    = (DEPTH <= 256);
    localparam int MDEPTH   = SMALL ? 256 : 512;
    localparam int MAW      = SMALL ? 8 : 9;
    localparam int ROWS_M   = (DEPTH + MDEPTH - 1) / MDEPTH;
    localparam int RSW      = (ROWS_M > 1) ? $clog2(ROWS_M) : 1;
    localparam int MASK_PER = LANE_W / 8;                   // mask bits per lane
    localparam int WW       = LANES * LANE_W;

    logic              we_q;
    logic [AW-1:0]     waddr_q;
    logic [LW-1:0]     wlane_q;
    logic [LANE_W-1:0] wdata_q;

    always_ff @(posedge clk) begin
        we_q    <= we_i;
        waddr_q <= waddr_i;
        wlane_q <= wlane_i;
        wdata_q <= wdata_i;
    end

    // Address of a word inside a macro, and which row of macros holds it.
    logic [MAW-1:0] waddr_m, raddr_m;
    logic [RSW-1:0] wrow, rrow, rrow_q;

    if (ROWS_M > 1) begin : g_rows
        assign waddr_m = waddr_q[MAW-1:0];
        assign raddr_m = raddr_i[MAW-1:0];
        assign wrow    = waddr_q[AW-1:MAW];
        assign rrow    = raddr_i[AW-1:MAW];
    end else begin : g_one_row
        assign waddr_m = MAW'(waddr_q);
        assign raddr_m = MAW'(raddr_i);
        assign wrow    = '0;
        assign rrow    = '0;
    end

    logic [COLS_M*MACRO_W-1:0] dout [0:ROWS_M-1];

    for (genvar r = 0; r < ROWS_M; r++) begin : g_r
        for (genvar c = 0; c < COLS_M; c++) begin : g_c
            logic        csb0, csb1;
            logic [3:0]  wmask;
            logic [31:0] din;

            // Lane wlane_i lives in column wlane_i / PER, at position
            // wlane_i % PER inside the macro word.
            always_comb begin
                wmask = '0;
                for (int p = 0; p < PER; p++) begin
                    if (c * PER + p < LANES && wlane_q == LW'(c * PER + p)) begin
                        wmask[p*MASK_PER +: MASK_PER] = '1;
                    end
                end
            end
            assign csb0 = !(we_q && (wrow == RSW'(r)) && (wmask != '0));
            assign csb1 = !(re_i && (rrow == RSW'(r)));
            assign din  = {PER{wdata_q}};

            if (SMALL) begin : g_1k
                sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
                    .clk0  (clk), .csb0(csb0), .web0(1'b0), .wmask0(wmask),
                    .addr0 (waddr_m), .din0(din), .dout0(),
                    .clk1  (clk), .csb1(csb1), .addr1(raddr_m),
                    .dout1 (dout[r][c*MACRO_W +: MACRO_W])
                );
`ifndef SYNTHESIS
                defparam u_sram.VERBOSE = 0;
`endif
            end else begin : g_2k
                sky130_sram_2kbyte_1rw1r_32x512_8 u_sram (
                    .clk0  (clk), .csb0(csb0), .web0(1'b0), .wmask0(wmask),
                    .addr0 (waddr_m), .din0(din), .dout0(),
                    .clk1  (clk), .csb1(csb1), .addr1(raddr_m),
                    .dout1 (dout[r][c*MACRO_W +: MACRO_W])
                );
`ifndef SYNTHESIS
                defparam u_sram.VERBOSE = 0;
`endif
            end
        end
    end

    // Read data: the macro output in the cycle after a read, else the held
    // word.
    logic re_q;
    logic [WW-1:0] hold_q, fresh;

    assign fresh   = WW'(dout[rrow_q]);
    assign rdata_o = re_q ? fresh : hold_q;

    always_ff @(posedge clk) begin
        re_q   <= re_i;
        hold_q <= rdata_o;
        if (re_i) rrow_q <= rrow;
    end

endmodule
