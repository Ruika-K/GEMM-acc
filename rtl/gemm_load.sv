// -----------------------------------------------------------------------------
// gemm_load: writes a row-major element stream into the operand memories.
//
// The host sends matrices in plain row-major order. The memories, however,
// store one word per (tile, k) so that a whole column segment of A or row
// segment of B can be read in one cycle:
//
//   A[i][k]  -> a_mem[(i / ROWS) * K + k], lane i % ROWS
//   B[k][j]  -> b_mem[(j / COLS) * K + k], lane j % COLS
//   bias[j]  -> bias_mem[j / COLS],        lane j % COLS
//
// The address arithmetic is done with counters and one adder (no multiplier,
// no divider). Bias is the B mapping with K = 1.
//
// A load consumes exactly M*K, K*N or N elements; TLAST is not needed. If the
// matrix does not fit, the offending writes are dropped and err_o pulses.
// -----------------------------------------------------------------------------
module gemm_load #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int DIM_W      = 16,
    parameter int K_MAX      = 1024,
    parameter int A_DEPTH    = 1024,
    parameter int B_DEPTH    = 1024,
    parameter int BIAS_DEPTH = 64,
    localparam int A_AW    = (A_DEPTH > 1) ? $clog2(A_DEPTH) : 1,
    localparam int B_AW    = (B_DEPTH > 1) ? $clog2(B_DEPTH) : 1,
    localparam int BIAS_AW = (BIAS_DEPTH > 1) ? $clog2(BIAS_DEPTH) : 1,
    localparam int RLW     = (ROWS > 1) ? $clog2(ROWS) : 1,
    localparam int CLW     = (COLS > 1) ? $clog2(COLS) : 1
) (
    input  logic               clk,
    input  logic               rst_n,

    // One-cycle requests; only issued while busy_o is low.
    input  logic               start_a_i,
    input  logic               start_b_i,
    input  logic               start_bias_i,
    input  logic [DIM_W-1:0]   m_i,
    input  logic [DIM_W-1:0]   k_i,
    input  logic [DIM_W-1:0]   n_i,

    output logic               busy_o,
    output logic               done_o,     // pulse: last element written
    output logic               err_o,      // pulse: matrix does not fit

    // Element stream
    input  logic               s_valid_i,
    output logic               s_ready_o,

    // Memory write strobes (the element itself goes straight to the memories)
    output logic               a_we_o,
    output logic [A_AW-1:0]    a_addr_o,
    output logic [RLW-1:0]     a_lane_o,
    output logic               b_we_o,
    output logic [B_AW-1:0]    b_addr_o,
    output logic [CLW-1:0]     b_lane_o,
    output logic               bias_we_o,
    output logic [BIAS_AW-1:0] bias_addr_o,
    output logic [CLW-1:0]     bias_lane_o
);

    // Wide enough for the largest depth plus one stride, so an out-of-range
    // address is always seen before the counter could wrap.
    localparam int MAX_DEPTH = (A_DEPTH > B_DEPTH)
                             ? ((A_DEPTH > BIAS_DEPTH) ? A_DEPTH : BIAS_DEPTH)
                             : ((B_DEPTH > BIAS_DEPTH) ? B_DEPTH : BIAS_DEPTH);
    localparam int AWI = $clog2(MAX_DEPTH + K_MAX + 1);
    localparam int LWI = (RLW > CLW) ? RLW : CLW;

    typedef enum logic [1:0] {T_NONE, T_A, T_B, T_BIAS} target_e;
    target_e target_q;

    logic [AWI-1:0]   addr_q;      // word being written
    logic [AWI-1:0]   base_q;      // A: first word of the band; B: current k
    logic [AWI-1:0]   stride_q;    // K (1 for bias)
    logic [LWI-1:0]   lane_q;
    logic [DIM_W-1:0] col_q;       // elements left in the stream row, minus one
    logic [DIM_W-1:0] cols_q;      // stream row length, minus one
    logic [DIM_W-1:0] rows_q;      // stream rows left
    logic             ovf_q;       // an out-of-range write was dropped

    logic beat, row_end, lane_end, in_range;
    logic [AWI-1:0] depth;

    always_comb begin
        case (target_q)
            T_A:     depth = AWI'(A_DEPTH);
            T_B:     depth = AWI'(B_DEPTH);
            default: depth = AWI'(BIAS_DEPTH);
        endcase
    end

    assign busy_o    = (target_q != T_NONE);
    assign s_ready_o = busy_o;
    assign beat      = s_valid_i && s_ready_o;
    // A down counter: the row ends at zero, with no subtraction or compare
    // against the row length in the way.
    assign row_end   = (col_q == '0);
    assign lane_end  = (target_q == T_A) ? (lane_q == LWI'(ROWS - 1))
                                         : (lane_q == LWI'(COLS - 1));
    assign in_range  = (addr_q < depth) && !ovf_q;

    assign a_we_o      = beat && in_range && (target_q == T_A);
    assign b_we_o      = beat && in_range && (target_q == T_B);
    assign bias_we_o   = beat && in_range && (target_q == T_BIAS);
    assign a_addr_o    = addr_q[A_AW-1:0];
    assign b_addr_o    = addr_q[B_AW-1:0];
    assign bias_addr_o = addr_q[BIAS_AW-1:0];
    assign a_lane_o    = lane_q[RLW-1:0];
    assign b_lane_o    = lane_q[CLW-1:0];
    assign bias_lane_o = lane_q[CLW-1:0];

    always_ff @(posedge clk) begin
        done_o <= 1'b0;
        err_o  <= 1'b0;
        if (!rst_n) begin
            target_q <= T_NONE;
        end else if (!busy_o) begin
            addr_q <= '0;
            base_q <= '0;
            lane_q <= '0;
            ovf_q  <= 1'b0;
            if (start_a_i) begin
                target_q <= T_A;
                stride_q <= AWI'(k_i);
                cols_q   <= k_i - 1'b1;
                col_q    <= k_i - 1'b1;
                rows_q   <= m_i;
            end else if (start_b_i) begin
                target_q <= T_B;
                stride_q <= AWI'(k_i);
                cols_q   <= n_i - 1'b1;
                col_q    <= n_i - 1'b1;
                rows_q   <= k_i;
            end else if (start_bias_i) begin
                target_q <= T_BIAS;
                stride_q <= AWI'(1);
                cols_q   <= n_i - 1'b1;
                col_q    <= n_i - 1'b1;
                rows_q   <= DIM_W'(1);
            end
        end else if (beat) begin
            if (!in_range && !ovf_q) begin
                ovf_q <= 1'b1;
                err_o <= 1'b1;
            end

            if (target_q == T_A) begin
                // Lane = row inside the band; the word address follows k.
                if (!row_end) begin
                    addr_q <= addr_q + 1'b1;
                end else if (lane_end) begin
                    lane_q <= '0;
                    base_q <= base_q + stride_q;
                    addr_q <= base_q + stride_q;
                end else begin
                    lane_q <= lane_q + 1'b1;
                    addr_q <= base_q;
                end
            end else begin
                // Lane = column inside the tile; the word address jumps by K
                // from one tile column to the next, base_q is the current k.
                if (row_end) begin
                    lane_q <= '0;
                    base_q <= base_q + 1'b1;
                    addr_q <= base_q + 1'b1;
                end else if (lane_end) begin
                    lane_q <= '0;
                    addr_q <= addr_q + stride_q;
                end else begin
                    lane_q <= lane_q + 1'b1;
                end
            end

            if (row_end) begin
                col_q  <= cols_q;
                rows_q <= rows_q - 1'b1;
                if (rows_q == DIM_W'(1)) begin
                    target_q <= T_NONE;
                    done_o   <= 1'b1;
                end
            end else begin
                col_q <= col_q - 1'b1;
            end
        end
    end

endmodule
