// -----------------------------------------------------------------------------
// gemm_seq: turns one "run" into the three input streams of gemm_core.
//
//   cmd  one command per tile
//   ab   K beats per tile, read from the A and B memories
//   d    tile_m beats per tile, the bias word of the tile column repeated
//
// Each stream has its own tile iterator and runs as far ahead as its consumer
// allows. In particular the command of the next tile is offered while the
// current tile is still computing, which is what lets gemm_core overlap the
// drain of one tile with the preload of the next.
//
// Memory layout (see gemm_load): word (tile, k) of A is at band * K + k, of B
// at col * K + k, so both read addresses simply count up within a tile.
// -----------------------------------------------------------------------------
module gemm_seq #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int DIM_W      = 16,
    parameter int K_MAX      = 1024,
    parameter int A_DEPTH    = 1024,
    parameter int B_DEPTH    = 1024,
    parameter int BIAS_DEPTH = 64,
    localparam int A_AW    = (A_DEPTH > 1) ? $clog2(A_DEPTH) : 1,
    localparam int B_AW    = (B_DEPTH > 1) ? $clog2(B_DEPTH) : 1,
    localparam int BIAS_AW = (BIAS_DEPTH > 1) ? $clog2(BIAS_DEPTH) : 1
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       start_i,     // pulse, dimensions are stable
    input  logic [DIM_W-1:0]           m_i,
    /* verilator lint_off UNUSED */
    input  logic [DIM_W-1:0]           k_i,         // checked to be <= K_MAX
    /* verilator lint_on UNUSED */
    input  logic [DIM_W-1:0]           n_i,
    input  logic                       bias_en_i,

    // Command stream
    output logic                       cmd_valid_o,
    input  logic                       cmd_ready_i,
    output logic [$clog2(ROWS+1)-1:0]  cmd_m_o,
    output logic [$clog2(COLS+1)-1:0]  cmd_n_o,
    output logic [$clog2(K_MAX+1)-1:0] cmd_k_o,
    output logic                       cmd_has_d_o,

    // Operand stream: the data comes straight from the memory outputs
    output logic                       ab_valid_o,
    input  logic                       ab_ready_i,
    output logic                       ab_re_o,
    output logic [A_AW-1:0]            a_addr_o,
    output logic [B_AW-1:0]            b_addr_o,

    // Bias stream
    output logic                       d_valid_o,
    input  logic                       d_ready_i,
    output logic                       bias_re_o,
    output logic [BIAS_AW-1:0]         bias_addr_o
);

    localparam int MW = $clog2(ROWS + 1);
    localparam int KW = $clog2(K_MAX + 1);

    logic [KW-1:0] k;
    assign k = k_i[KW-1:0];

    // ------------------------------------------------------------------
    // Commands
    // ------------------------------------------------------------------
    logic cmd_next;

    gemm_tile_iter #(.ROWS(ROWS), .COLS(COLS), .DIM_W(DIM_W)) u_cmd_iter (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_i   (start_i),
        .m_i       (m_i),
        .n_i       (n_i),
        .next_i    (cmd_next),
        .valid_o   (cmd_valid_o),
        .tile_m_o  (cmd_m_o),
        .tile_n_o  (cmd_n_o),
        /* verilator lint_off PINCONNECTEMPTY */
        .col_last_o(),
        .last_o    ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    assign cmd_next    = cmd_valid_o && cmd_ready_i;
    assign cmd_k_o     = k;
    assign cmd_has_d_o = bias_en_i;

    // ------------------------------------------------------------------
    // Operands. The memories have a registered output with read enable, so
    // the output register itself is the stream's holding stage: a new word is
    // read whenever the stage is empty or its beat is being taken.
    // ------------------------------------------------------------------
    logic            ab_it_valid, ab_it_col_last, ab_next;
    logic            ab_advance, ab_tile_end;
    logic [KW-1:0]   ab_k_q;                  // reads still to issue for the tile, minus one
    logic [A_AW-1:0] a_addr_q, a_base_q;
    logic [B_AW-1:0] b_addr_q, b_base_q;

    gemm_tile_iter #(.ROWS(ROWS), .COLS(COLS), .DIM_W(DIM_W)) u_ab_iter (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_i   (start_i),
        .m_i       (m_i),
        .n_i       (n_i),
        .next_i    (ab_next),
        .valid_o   (ab_it_valid),
        /* verilator lint_off PINCONNECTEMPTY */
        .tile_m_o  (),
        .tile_n_o  (),
        .col_last_o(ab_it_col_last),
        .last_o    ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    assign ab_advance  = !ab_valid_o || ab_ready_i;
    assign ab_re_o     = ab_advance && ab_it_valid;
    // Counting down to zero keeps the dimension register and its decrement
    // out of the path that advances the tile iterator.
    assign ab_tile_end = (ab_k_q == '0);
    assign ab_next     = ab_re_o && ab_tile_end;
    assign a_addr_o    = a_addr_q;
    assign b_addr_o    = b_addr_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ab_valid_o <= 1'b0;
        end else if (start_i) begin
            ab_valid_o <= 1'b0;
        end else if (ab_advance) begin
            ab_valid_o <= ab_re_o;
        end
    end

    always_ff @(posedge clk) begin
        if (start_i) begin
            ab_k_q   <= k - 1'b1;
            a_addr_q <= '0;
            a_base_q <= '0;
            b_addr_q <= '0;
            b_base_q <= '0;
        end else if (ab_re_o) begin
            if (!ab_tile_end) begin
                ab_k_q   <= ab_k_q - 1'b1;
                a_addr_q <= a_addr_q + 1'b1;
                b_addr_q <= b_addr_q + 1'b1;
            end else begin
                ab_k_q <= k - 1'b1;
                if (ab_it_col_last) begin
                    // Next band: next segment of A, back to the first of B.
                    a_base_q <= a_base_q + A_AW'(k);
                    a_addr_q <= a_base_q + A_AW'(k);
                    b_base_q <= '0;
                    b_addr_q <= '0;
                end else begin
                    // Same band: same segment of A, next segment of B.
                    a_addr_q <= a_base_q;
                    b_base_q <= b_base_q + B_AW'(k);
                    b_addr_q <= b_base_q + B_AW'(k);
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Bias: one memory read per tile, then the same word for tile_m beats.
    // ------------------------------------------------------------------
    logic               d_it_valid, d_it_col_last, d_next;
    logic [MW-1:0]      d_tile_m;
    logic               d_loaded_q;            // memory output holds this tile's word
    logic [MW-1:0]      d_row_q;
    logic [BIAS_AW-1:0] d_col_q;               // tile column = bias word address
    logic               d_beat;

    gemm_tile_iter #(.ROWS(ROWS), .COLS(COLS), .DIM_W(DIM_W)) u_d_iter (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_i   (start_i && bias_en_i),
        .m_i       (m_i),
        .n_i       (n_i),
        .next_i    (d_next),
        .valid_o   (d_it_valid),
        .tile_m_o  (d_tile_m),
        /* verilator lint_off PINCONNECTEMPTY */
        .tile_n_o  (),
        .col_last_o(d_it_col_last),
        .last_o    ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    assign bias_re_o   = d_it_valid && !d_loaded_q;
    assign bias_addr_o = d_col_q;
    assign d_valid_o   = d_it_valid && d_loaded_q;
    assign d_beat      = d_valid_o && d_ready_i;
    assign d_next      = d_beat && (d_row_q == d_tile_m - 1'b1);

    always_ff @(posedge clk) begin
        if (!rst_n || start_i) begin
            d_loaded_q <= 1'b0;
            d_row_q    <= '0;
            d_col_q    <= '0;
        end else if (bias_re_o) begin
            d_loaded_q <= 1'b1;
            d_row_q    <= '0;
        end else if (d_beat) begin
            d_row_q <= d_row_q + 1'b1;
            if (d_next) begin
                d_loaded_q <= 1'b0;
                d_col_q    <= d_it_col_last ? '0 : d_col_q + 1'b1;
            end
        end
    end

endmodule
