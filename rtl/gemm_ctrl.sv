// -----------------------------------------------------------------------------
// gemm_ctrl: tile sequencer.
//
// The controller does not know about skew. It only decides, cycle by cycle,
// whether to issue a shift beat or an operand beat; the delay lines in
// gemm_core turn those beats into the timing the array expects.
//
//   S_SHIFT  ROWS shift beats. Each beat drains one row of the tile that was
//            just computed (if any) and preloads one row of the next tile
//            (if any). A beat waits for the D stream and for output credit.
//   S_MAC    K operand beats, one per ab handshake.
//   S_WAIT   ROWS - 1 idle cycles so the last row of the array, which receives
//            its operands ROWS - 1 cycles late, can finish.
//
// One command is buffered, so a command that is already waiting when a tile
// finishes shares its preload with the drain of that tile.
//
// Output flow control is credit based: a result row needs COLS + PE_PIPE cycles
// to travel from the decision point to the output FIFO, so a row is only
// released when a FIFO slot has been reserved for it.
// -----------------------------------------------------------------------------
module gemm_ctrl #(
    parameter int ROWS      = 8,
    parameter int COLS      = 8,
    parameter int K_MAX     = 1024,
    parameter int OUT_DEPTH = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Tile command. m, n, k must be at least 1.
    input  logic                         cmd_valid_i,
    output logic                         cmd_ready_o,
    input  logic [$clog2(ROWS+1)-1:0]    cmd_m_i,
    input  logic [$clog2(COLS+1)-1:0]    cmd_n_i,
    input  logic [$clog2(K_MAX+1)-1:0]   cmd_k_i,
    input  logic                         cmd_has_d_i,

    // Stream handshakes
    input  logic                         d_valid_i,
    output logic                         d_ready_o,
    input  logic                         ab_valid_i,
    output logic                         ab_ready_o,
    input  logic                         c_pop_i,     // a row left the output FIFO

    // Beats issued in this cycle
    output logic                         shift_o,     // shift beat
    output logic                         d_take_o,    // beat consumes a D row
    output logic                         c_valid_o,   // beat drains a result row
    output logic                         c_last_o,    // ... the last one of its tile
    output logic                         mac_o,       // operand beat
    output logic [COLS-1:0]              col_en_o,    // columns < n

    output logic                         idle_o
);

    localparam int MW = $clog2(ROWS + 1);
    localparam int NW = $clog2(COLS + 1);
    localparam int KW = $clog2(K_MAX + 1);
    localparam int CW = $clog2(OUT_DEPTH + 1);

    typedef enum logic [1:0] {S_IDLE, S_SHIFT, S_MAC, S_WAIT} state_e;
    state_e state_q;

    // Buffered command
    logic          pend_valid_q;
    logic [MW-1:0] pend_m_q;
    logic [NW-1:0] pend_n_q;
    logic [KW-1:0] pend_k_q;
    logic          pend_has_d_q;

    // Tile being preloaded / computed
    logic            cur_valid_q;
    logic [MW-1:0]   cur_m_q;
    logic [KW-1:0]   cur_k_q;
    logic            cur_has_d_q;
    logic [COLS-1:0] cur_col_en_q;

    // Tile being drained
    logic          prev_valid_q;
    logic [MW-1:0] prev_m_q;

    logic [MW-1:0] row_q;      // shift beat counter, 0 .. ROWS-1
    logic [MW-1:0] wait_q;     // idle cycle counter
    logic [CW-1:0] credit_q;   // free output FIFO slots not yet promised

    // Next values of the registers above, and the decisions for the next
    // cycle worked out from them. The beat decisions of a cycle are then
    // registered flags: d_valid_i, ab_valid_i and c_pop_i, which arrive from
    // other blocks, meet registers only, and the counters and comparators
    // are on paths from register to register. (Comparing row_q with the tile
    // height and k with the tile depth in the same cycle as the beat they
    // decide put the controller, the D stream and its tile iterator in one
    // path of 7 - 8 ns at the slow corner.)
    state_e          state_n;
    logic            pend_valid_n, cur_valid_n, prev_valid_n, cur_has_d_n;
    logic [MW-1:0]   cur_m_n, prev_m_n, row_n, wait_n;
    logic [KW-1:0]   cur_k_n;
    logic [CW-1:0]   credit_n;

    logic need_d_q;       // this shift beat preloads a D row
    logic need_credit_q;  // this shift beat drains a result row
    logic last_row_q;     // ... the last one of the drained tile
    logic credit_ok_q;    // a FIFO slot is free
    logic shift_last_q;   // this shift beat is the last of the phase
    logic k_last_q;       // this operand beat is the last of the tile (u_kcnt)

    // ------------------------------------------------------------------
    // Beat decisions
    // ------------------------------------------------------------------
    logic in_shift, shift_fire, mac_fire;

    assign in_shift   = (state_q == S_SHIFT);
    assign shift_fire = in_shift && (!need_d_q || d_valid_i) && (!need_credit_q || credit_ok_q);
    assign mac_fire   = (state_q == S_MAC) && ab_valid_i;

    // Ready signals depend on registered state only, never on the valid they
    // answer or on another channel's valid.
    assign cmd_ready_o = !pend_valid_q;
    assign d_ready_o   = in_shift && need_d_q && (!need_credit_q || credit_ok_q);
    assign ab_ready_o  = (state_q == S_MAC);

    assign shift_o   = shift_fire;
    assign d_take_o  = shift_fire && need_d_q;
    assign c_valid_o = shift_fire && need_credit_q;
    assign c_last_o  = c_valid_o && last_row_q;
    assign mac_o     = mac_fire;
    assign col_en_o  = cur_col_en_q;

    assign idle_o = (state_q == S_IDLE) && !pend_valid_q && (credit_q == CW'(OUT_DEPTH));

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    // Start a shift phase: the buffered command (if any) becomes the current
    // tile, and the tile that was current (if it was computed) is drained.
    logic start_shift, start_from_tile, cmd_take;

    assign cmd_take = cmd_valid_i && cmd_ready_o;

    always_comb begin
        start_shift     = 1'b0;
        start_from_tile = 1'b0;
        case (state_q)
            S_IDLE:  start_shift = pend_valid_q;
            S_MAC: begin
                start_shift     = mac_fire && k_last_q && (ROWS == 1);
                start_from_tile = 1'b1;
            end
            S_WAIT: begin
                start_shift     = (wait_q == '0);
                start_from_tile = 1'b1;
            end
            default: ;
        endcase
    end

    always_comb begin
        state_n      = state_q;
        pend_valid_n = pend_valid_q;
        cur_valid_n  = cur_valid_q;
        cur_m_n      = cur_m_q;
        cur_k_n      = cur_k_q;
        cur_has_d_n  = cur_has_d_q;
        prev_valid_n = prev_valid_q;
        prev_m_n     = prev_m_q;
        row_n        = row_q;
        wait_n       = wait_q;

        case (state_q)
            S_SHIFT: begin
                if (shift_fire) begin
                    if (shift_last_q) begin
                        row_n        = '0;
                        prev_valid_n = 1'b0;
                        if (cur_valid_q) state_n = S_MAC;
                        else             state_n = S_IDLE;
                    end else begin
                        row_n = row_q + 1'b1;
                    end
                end
            end
            S_MAC: begin
                if (mac_fire) begin
                    if (k_last_q) begin
                        wait_n  = MW'(ROWS - 2);
                        state_n = S_WAIT;
                    end
                end
            end
            S_WAIT: wait_n = wait_q - 1'b1;
            default: ;
        endcase

        if (start_shift) begin
            state_n      = S_SHIFT;
            row_n        = '0;
            prev_valid_n = start_from_tile;
            prev_m_n     = cur_m_q;
            cur_valid_n  = pend_valid_q;
            cur_m_n      = pend_m_q;
            cur_k_n      = pend_k_q;
            cur_has_d_n  = pend_has_d_q;
            pend_valid_n = 1'b0;
        end
        if (cmd_take) pend_valid_n = 1'b1;
    end

    // Operand beats left in the tile: only "the last one" is needed, so it is
    // a gemm_dcnt counter, loaded with the tile depth when the shift phase
    // before the tile ends. In the placed chip both a plain 11-bit decrement
    // (5 OR gates deep) and the comparison of its result with 1 behind the
    // beat decision were the longest path. k_last_q is only read in S_MAC,
    // which is entered through that load.
    gemm_dcnt #(.W(KW)) u_kcnt (
        .clk     (clk),
        .load_i  (in_shift && shift_fire && shift_last_q),
        .value_i (cur_k_q),
        .reload_i(1'b0),
        .dec_i   (mac_fire),
        .last_o  (k_last_q)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q       <= S_IDLE;
            pend_valid_q  <= 1'b0;
            cur_valid_q   <= 1'b0;
            prev_valid_q  <= 1'b0;
            row_q         <= '0;
            wait_q        <= '0;
            need_d_q      <= 1'b0;
            need_credit_q <= 1'b0;
            shift_last_q  <= (ROWS == 1);   // row_q is 0
        end else begin
            state_q      <= state_n;
            pend_valid_q <= pend_valid_n;
            cur_valid_q  <= cur_valid_n;
            prev_valid_q <= prev_valid_n;
            row_q        <= row_n;
            wait_q       <= wait_n;

            need_d_q      <= cur_valid_n && cur_has_d_n && (row_n < cur_m_n);
            need_credit_q <= prev_valid_n && (row_n < prev_m_n);
            shift_last_q  <= (row_n == MW'(ROWS - 1));
        end
        // Not reset: only read while the flags above say they are valid.
        cur_m_q     <= cur_m_n;
        cur_k_q     <= cur_k_n;
        cur_has_d_q <= cur_has_d_n;
        prev_m_q    <= prev_m_n;
        last_row_q  <= (row_n == prev_m_n - 1'b1);
        if (start_shift) begin
            for (int j = 0; j < COLS; j++) cur_col_en_q[j] <= (NW'(j) < pend_n_q);
        end
        if (cmd_take) begin
            pend_m_q     <= cmd_m_i;
            pend_n_q     <= cmd_n_i;
            pend_k_q     <= cmd_k_i;
            pend_has_d_q <= cmd_has_d_i;
        end
    end

    // ------------------------------------------------------------------
    // Output credits
    // ------------------------------------------------------------------
    always_comb begin
        credit_n = credit_q;
        if (c_valid_o && !c_pop_i)      credit_n = credit_q - 1'b1;
        else if (!c_valid_o && c_pop_i) credit_n = credit_q + 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            credit_q    <= CW'(OUT_DEPTH);
            credit_ok_q <= 1'b1;
        end else begin
            credit_q    <= credit_n;
            credit_ok_q <= (credit_n != '0);
        end
    end

endmodule
