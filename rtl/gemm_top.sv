// -----------------------------------------------------------------------------
// gemm_top: GEMM accelerator with AXI interfaces.
//
//   C[M x N] = A[M x K] * B[K x N] + bias[N]      (bias optional, added to every row)
//
//   s_axi   AXI4-Lite   registers (see gemm_csr)
//   s_axis  AXI4-Stream operands in, one element per beat, row-major
//   m_axis  AXI4-Stream results out, one element per beat, tile order
//
// Typical sequence: write DIM_M / DIM_K / DIM_N, LOAD_A + stream A, LOAD_B +
// stream B, (LOAD_BIAS + stream bias), START, read M*N results. Operands stay
// in the memories, so a matrix can be reused by later runs.
//
//             +------+        +-----------+
//  s_axis --> | load | -----> | A/B/bias  | ---+
//             +------+        | memories  |    | a, b, d
//                             +-----------+    v
//             +------+  cmd, read addresses  +------+  rows  +-----+
//  s_axi  --> | csr  | --start--> | seq | -> | core | -----> | out | --> m_axis
//             +------+                       +------+        +-----+
// -----------------------------------------------------------------------------
module gemm_top #(
    parameter int DATA_W     = 8,
    parameter int ACC_W      = 32,
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int PE_PIPE    = 1,
    parameter int ACC_SEG    = 0,      // accumulator carry segments, see gemm_mac
    parameter int K_MAX      = 1024,
    parameter int OUT_DEPTH  = ROWS,
    parameter int A_DEPTH    = 1024,   // words of ROWS elements
    parameter int B_DEPTH    = 1024,   // words of COLS elements
    parameter int BIAS_DEPTH = 64,     // words of COLS elements
    parameter int DIM_W      = 16,
    parameter int MEM_SPLIT  = 0       // see gemm_mem: 1 = one RAM per lane
) (
    input  logic        aclk,
    input  logic        aresetn,      // synchronous, active low

    // AXI4-Lite slave
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [7:0]  s_axi_awaddr,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    output logic [1:0]  s_axi_bresp,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    input  logic [7:0]  s_axi_araddr,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,

    // AXI4-Stream slave: operand elements in the low bits of TDATA
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [31:0] s_axis_tdata,

    // AXI4-Stream master: sign-extended result elements
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tlast,

    output logic        irq_o         // level, follows STATUS.DONE
);

    localparam int A_AW    = (A_DEPTH > 1) ? $clog2(A_DEPTH) : 1;
    localparam int B_AW    = (B_DEPTH > 1) ? $clog2(B_DEPTH) : 1;
    localparam int BIAS_AW = (BIAS_DEPTH > 1) ? $clog2(BIAS_DEPTH) : 1;
    localparam int RLW     = (ROWS > 1) ? $clog2(ROWS) : 1;
    localparam int CLW     = (COLS > 1) ? $clog2(COLS) : 1;

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    logic [DIM_W-1:0] dim_m, dim_k, dim_n;
    logic             bias_en;
    logic             start, load_a, load_b, load_bias;
    logic             run_done, load_done, load_err;
    /* verilator lint_off UNUSED */
    logic             busy;            // visible through STATUS only
    /* verilator lint_on UNUSED */

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    gemm_csr #(
        .DATA_W(DATA_W),
        .ACC_W (ACC_W),
        .ROWS  (ROWS),
        .COLS  (COLS),
        .DIM_W (DIM_W),
        .K_MAX (K_MAX)
    ) u_csr (
        .clk        (aclk),
        .rst_n      (aresetn),
        .awvalid_i  (s_axi_awvalid),
        .awready_o  (s_axi_awready),
        .awaddr_i   (s_axi_awaddr),
        .wvalid_i   (s_axi_wvalid),
        .wready_o   (s_axi_wready),
        .wdata_i    (s_axi_wdata),
        .wstrb_i    (s_axi_wstrb),
        .bvalid_o   (s_axi_bvalid),
        .bready_i   (s_axi_bready),
        .arvalid_i  (s_axi_arvalid),
        .arready_o  (s_axi_arready),
        .araddr_i   (s_axi_araddr),
        .rvalid_o   (s_axi_rvalid),
        .rready_i   (s_axi_rready),
        .rdata_o    (s_axi_rdata),
        .m_o        (dim_m),
        .k_o        (dim_k),
        .n_o        (dim_n),
        .bias_en_o  (bias_en),
        .start_o    (start),
        .load_a_o   (load_a),
        .load_b_o   (load_b),
        .load_bias_o(load_bias),
        .run_done_i (run_done),
        .load_done_i(load_done),
        .load_err_i (load_err),
        .busy_o     (busy),
        .done_o     (irq_o)
    );

    // ------------------------------------------------------------------
    // Operand memories and loader
    // ------------------------------------------------------------------
    logic               a_we, b_we, bias_we;
    logic [A_AW-1:0]    a_waddr, a_raddr;
    logic [B_AW-1:0]    b_waddr, b_raddr;
    logic [BIAS_AW-1:0] bias_waddr, bias_raddr;
    logic [RLW-1:0]     a_wlane;
    logic [CLW-1:0]     b_wlane, bias_wlane;
    logic               ab_re, bias_re;
    /* verilator lint_off UNUSED */
    logic               load_busy;     // tracked by the register block
    /* verilator lint_on UNUSED */

    logic [ROWS-1:0][DATA_W-1:0] a_word;
    logic [COLS-1:0][DATA_W-1:0] b_word;
    logic [COLS-1:0][ACC_W-1:0]  bias_word;

    gemm_load #(
        .ROWS      (ROWS),
        .COLS      (COLS),
        .DIM_W     (DIM_W),
        .K_MAX     (K_MAX),
        .A_DEPTH   (A_DEPTH),
        .B_DEPTH   (B_DEPTH),
        .BIAS_DEPTH(BIAS_DEPTH)
    ) u_load (
        .clk         (aclk),
        .rst_n       (aresetn),
        .start_a_i   (load_a),
        .start_b_i   (load_b),
        .start_bias_i(load_bias),
        .m_i         (dim_m),
        .k_i         (dim_k),
        .n_i         (dim_n),
        .busy_o      (load_busy),
        .done_o      (load_done),
        .err_o       (load_err),
        .s_valid_i   (s_axis_tvalid),
        .s_ready_o   (s_axis_tready),
        .a_we_o      (a_we),
        .a_addr_o    (a_waddr),
        .a_lane_o    (a_wlane),
        .b_we_o      (b_we),
        .b_addr_o    (b_waddr),
        .b_lane_o    (b_wlane),
        .bias_we_o   (bias_we),
        .bias_addr_o (bias_waddr),
        .bias_lane_o (bias_wlane)
    );

    gemm_mem #(.LANES(ROWS), .LANE_W(DATA_W), .DEPTH(A_DEPTH), .SPLIT(MEM_SPLIT)) u_a_mem (
        .clk    (aclk),
        .we_i   (a_we),
        .waddr_i(a_waddr),
        .wlane_i(a_wlane),
        .wdata_i(s_axis_tdata[DATA_W-1:0]),
        .re_i   (ab_re),
        .raddr_i(a_raddr),
        .rdata_o(a_word)
    );

    gemm_mem #(.LANES(COLS), .LANE_W(DATA_W), .DEPTH(B_DEPTH), .SPLIT(MEM_SPLIT)) u_b_mem (
        .clk    (aclk),
        .we_i   (b_we),
        .waddr_i(b_waddr),
        .wlane_i(b_wlane),
        .wdata_i(s_axis_tdata[DATA_W-1:0]),
        .re_i   (ab_re),
        .raddr_i(b_raddr),
        .rdata_o(b_word)
    );

    gemm_mem #(.LANES(COLS), .LANE_W(ACC_W), .DEPTH(BIAS_DEPTH), .SPLIT(MEM_SPLIT)) u_bias_mem (
        .clk    (aclk),
        .we_i   (bias_we),
        .waddr_i(bias_waddr),
        .wlane_i(bias_wlane),
        .wdata_i(s_axis_tdata[ACC_W-1:0]),
        .re_i   (bias_re),
        .raddr_i(bias_raddr),
        .rdata_o(bias_word)
    );

    // ------------------------------------------------------------------
    // Sequencer and core
    // ------------------------------------------------------------------
    logic                       cmd_valid, cmd_ready, cmd_has_d;
    logic [$clog2(ROWS+1)-1:0]  cmd_m;
    logic [$clog2(COLS+1)-1:0]  cmd_n;
    logic [$clog2(K_MAX+1)-1:0] cmd_k;
    logic                       ab_valid, ab_ready, d_valid, d_ready;
    logic                       c_valid, c_ready, c_last;
    logic [COLS-1:0][ACC_W-1:0] c_row;

    gemm_seq #(
        .ROWS      (ROWS),
        .COLS      (COLS),
        .DIM_W     (DIM_W),
        .K_MAX     (K_MAX),
        .A_DEPTH   (A_DEPTH),
        .B_DEPTH   (B_DEPTH),
        .BIAS_DEPTH(BIAS_DEPTH)
    ) u_seq (
        .clk        (aclk),
        .rst_n      (aresetn),
        .start_i    (start),
        .m_i        (dim_m),
        .k_i        (dim_k),
        .n_i        (dim_n),
        .bias_en_i  (bias_en),
        .cmd_valid_o(cmd_valid),
        .cmd_ready_i(cmd_ready),
        .cmd_m_o    (cmd_m),
        .cmd_n_o    (cmd_n),
        .cmd_k_o    (cmd_k),
        .cmd_has_d_o(cmd_has_d),
        .ab_valid_o (ab_valid),
        .ab_ready_i (ab_ready),
        .ab_re_o    (ab_re),
        .a_addr_o   (a_raddr),
        .b_addr_o   (b_raddr),
        .d_valid_o  (d_valid),
        .d_ready_i  (d_ready),
        .bias_re_o  (bias_re),
        .bias_addr_o(bias_raddr)
    );

    gemm_core #(
        .DATA_W   (DATA_W),
        .ACC_W    (ACC_W),
        .ROWS     (ROWS),
        .COLS     (COLS),
        .PE_PIPE  (PE_PIPE),
        .ACC_SEG  (ACC_SEG),
        .K_MAX    (K_MAX),
        .OUT_DEPTH(OUT_DEPTH)
    ) u_core (
        .clk        (aclk),
        .rst_n      (aresetn),
        .cmd_valid_i(cmd_valid),
        .cmd_ready_o(cmd_ready),
        .cmd_m_i    (cmd_m),
        .cmd_n_i    (cmd_n),
        .cmd_k_i    (cmd_k),
        .cmd_has_d_i(cmd_has_d),
        .d_valid_i  (d_valid),
        .d_ready_o  (d_ready),
        .d_i        (bias_word),
        .ab_valid_i (ab_valid),
        .ab_ready_o (ab_ready),
        .a_i        (a_word),
        .b_i        (b_word),
        .c_valid_o  (c_valid),
        .c_ready_i  (c_ready),
        .c_last_o   (c_last),
        .c_o        (c_row),
        /* verilator lint_off PINCONNECTEMPTY */
        .idle_o     ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ------------------------------------------------------------------
    // Result serialiser
    // ------------------------------------------------------------------
    gemm_out #(
        .ACC_W (ACC_W),
        .ROWS  (ROWS),
        .COLS  (COLS),
        .DIM_W (DIM_W),
        .AXIS_W(32)
    ) u_out (
        .clk      (aclk),
        .rst_n    (aresetn),
        .start_i  (start),
        .m_i      (dim_m),
        .n_i      (dim_n),
        .done_o   (run_done),
        .c_valid_i(c_valid),
        .c_ready_o(c_ready),
        .c_last_i (c_last),
        .c_i      (c_row),
        .m_valid_o(m_axis_tvalid),
        .m_ready_i(m_axis_tready),
        .m_data_o (m_axis_tdata),
        .m_last_o (m_axis_tlast)
    );

endmodule
