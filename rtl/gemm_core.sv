// -----------------------------------------------------------------------------
// gemm_core: one-tile GEMM engine.
//
//   C[m x n] = A[m x k] * B[k x n] + D[m x n],  m <= ROWS, n <= COLS, k <= K_MAX
//
// Streams (all valid / ready):
//   cmd   one beat per tile: m, n, k, has_d
//   d     m beats per tile (only if has_d): row r of D, COLS words
//   ab    k beats per tile: column k of A (ROWS words) and row k of B (COLS words)
//   c     m beats per tile: row r of C, COLS words; c_last_o marks row m - 1
//
// Unused rows and columns are handled inside the core: B and D columns >= n
// are forced to zero, so C columns >= n read as zero; rows >= m still compute
// but are never drained.
//
//            +------+   beats   +----------+     +-------+     +---------+
//   cmd ---> | ctrl | --------> | input    | --> | skew  | --> |  array  |
//   d, ab -> |      |           | register |     | lines |     |         |
//            +------+           +----------+     +-------+     +---------+
//               ^ credit                                            |
//               |                 +------+     +---------+          |
//   c  <--------+-----------------| FIFO | <-- | de-skew | <--------+
//                                 +------+     +---------+
// -----------------------------------------------------------------------------
module gemm_core #(
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int ROWS      = 8,
    parameter int COLS      = 8,
    parameter int PE_PIPE   = 1,
    parameter int K_MAX     = 1024,
    parameter int OUT_DEPTH = ROWS    // output FIFO depth in rows
) (
    input  logic                              clk,
    input  logic                              rst_n,

    input  logic                              cmd_valid_i,
    output logic                              cmd_ready_o,
    input  logic [$clog2(ROWS+1)-1:0]         cmd_m_i,
    input  logic [$clog2(COLS+1)-1:0]         cmd_n_i,
    input  logic [$clog2(K_MAX+1)-1:0]        cmd_k_i,
    input  logic                              cmd_has_d_i,

    input  logic                              d_valid_i,
    output logic                              d_ready_o,
    input  logic [COLS-1:0][ACC_W-1:0]        d_i,

    input  logic                              ab_valid_i,
    output logic                              ab_ready_o,
    input  logic [ROWS-1:0][DATA_W-1:0]       a_i,
    input  logic [COLS-1:0][DATA_W-1:0]       b_i,

    output logic                              c_valid_o,
    input  logic                              c_ready_i,
    output logic                              c_last_o,
    output logic [COLS-1:0][ACC_W-1:0]        c_o,

    output logic                              idle_o
);

    // ------------------------------------------------------------------
    // Controller
    // ------------------------------------------------------------------
    logic            beat_shift, beat_d_take, beat_c_valid, beat_c_last, beat_mac;
    logic [COLS-1:0] col_en;
    logic            c_pop;

    gemm_ctrl #(
        .ROWS     (ROWS),
        .COLS     (COLS),
        .K_MAX    (K_MAX),
        .OUT_DEPTH(OUT_DEPTH)
    ) u_ctrl (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_m_i    (cmd_m_i),
        .cmd_n_i    (cmd_n_i),
        .cmd_k_i    (cmd_k_i),
        .cmd_has_d_i(cmd_has_d_i),
        .d_valid_i  (d_valid_i),
        .d_ready_o  (d_ready_o),
        .ab_valid_i (ab_valid_i),
        .ab_ready_o (ab_ready_o),
        .c_pop_i    (c_pop),
        .shift_o    (beat_shift),
        .d_take_o   (beat_d_take),
        .c_valid_o  (beat_c_valid),
        .c_last_o   (beat_c_last),
        .mac_o      (beat_mac),
        .col_en_o   (col_en),
        .idle_o     (idle_o)
    );

    // ------------------------------------------------------------------
    // Input register: every beat is registered once before it enters the
    // delay lines, so no handshake logic sits in front of a multiplier.
    // Operand registers hold their value outside operand beats to keep the
    // multipliers quiet.
    // ------------------------------------------------------------------
    logic                         shift_q;
    logic [1:0]                   tag_q;       // {c_last, c_valid}
    logic [ROWS-1:0]              av_q;
    logic [ROWS-1:0][DATA_W-1:0]  a_q;
    logic [COLS-1:0][DATA_W-1:0]  b_q;
    logic [COLS-1:0][ACC_W-1:0]   d_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shift_q <= 1'b0;
            tag_q   <= 2'b00;
            av_q    <= '0;
        end else begin
            shift_q <= beat_shift;
            tag_q   <= {beat_c_last, beat_c_valid};
            av_q    <= {ROWS{beat_mac}};
        end
    end

    always_ff @(posedge clk) begin
        if (beat_mac) begin
            a_q <= a_i;
            for (int j = 0; j < COLS; j++) b_q[j] <= col_en[j] ? b_i[j] : '0;
        end
        if (beat_shift) begin
            for (int j = 0; j < COLS; j++) begin
                d_q[j] <= (beat_d_take && col_en[j]) ? d_i[j] : '0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Skew: row i of A by i cycles, column j of B by j cycles, column j of D
    // by j + PE_PIPE cycles (the cycle in which that column shifts).
    // ------------------------------------------------------------------
    logic [ROWS-1:0]              av_skew;
    logic [ROWS-1:0][DATA_W-1:0]  a_skew;
    logic [COLS-1:0][DATA_W-1:0]  b_skew;
    logic [COLS-1:0][ACC_W-1:0]   d_skew;

    generate
        for (genvar i = 0; i < ROWS; i++) begin : g_a_skew
            gemm_delay #(.WIDTH(1), .STAGES(i), .RESET(1)) u_av (
                .clk(clk), .rst_n(rst_n), .d_i(av_q[i]), .q_o(av_skew[i])
            );
            gemm_delay #(.WIDTH(DATA_W), .STAGES(i), .RESET(0)) u_a (
                .clk(clk), .rst_n(rst_n), .d_i(a_q[i]), .q_o(a_skew[i])
            );
        end
        for (genvar j = 0; j < COLS; j++) begin : g_bd_skew
            gemm_delay #(.WIDTH(DATA_W), .STAGES(j), .RESET(0)) u_b (
                .clk(clk), .rst_n(rst_n), .d_i(b_q[j]), .q_o(b_skew[j])
            );
            gemm_delay #(.WIDTH(ACC_W), .STAGES(j + PE_PIPE), .RESET(0)) u_d (
                .clk(clk), .rst_n(rst_n), .d_i(d_q[j]), .q_o(d_skew[j])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Array
    // ------------------------------------------------------------------
    logic [COLS-1:0][ACC_W-1:0] c_arr;
    /* verilator lint_off UNUSED */
    logic [COLS-1:0]            c_arr_valid;   // timing is tracked by the tag line
    /* verilator lint_on UNUSED */

    gemm_array #(
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W),
        .ROWS   (ROWS),
        .COLS   (COLS),
        .PE_PIPE(PE_PIPE)
    ) u_array (
        .clk      (clk),
        .rst_n    (rst_n),
        .a_valid_i(av_skew),
        .a_i      (a_skew),
        .b_i      (b_skew),
        .shift_i  (shift_q),
        .c_i      (d_skew),
        .c_valid_o(c_arr_valid),
        .c_o      (c_arr)
    );

    // ------------------------------------------------------------------
    // De-skew: column j leaves the array j + PE_PIPE cycles after its shift
    // beat; delay it by COLS - 1 - j more so the whole row lines up. The tag
    // travels the same COLS - 1 + PE_PIPE cycles.
    // ------------------------------------------------------------------
    logic [COLS-1:0][ACC_W-1:0] c_row;
    logic [1:0]                 tag_d;

    generate
        for (genvar j = 0; j < COLS; j++) begin : g_c_deskew
            gemm_delay #(.WIDTH(ACC_W), .STAGES(COLS - 1 - j), .RESET(0)) u_c (
                .clk(clk), .rst_n(rst_n), .d_i(c_arr[j]), .q_o(c_row[j])
            );
        end
    endgenerate

    gemm_delay #(.WIDTH(2), .STAGES(COLS - 1 + PE_PIPE), .RESET(1)) u_tag (
        .clk(clk), .rst_n(rst_n), .d_i(tag_q), .q_o(tag_d)
    );

    // ------------------------------------------------------------------
    // Output FIFO
    // ------------------------------------------------------------------
    gemm_fifo #(
        .WIDTH(1 + COLS * ACC_W),
        .DEPTH(OUT_DEPTH)
    ) u_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .push_i (tag_d[0]),
        .data_i ({tag_d[1], c_row}),
        .valid_o(c_valid_o),
        .ready_i(c_ready_i),
        .data_o ({c_last_o, c_o})
    );

    assign c_pop = c_valid_o && c_ready_i;

endmodule
