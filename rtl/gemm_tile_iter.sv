// -----------------------------------------------------------------------------
// gemm_tile_iter: walks the tiles of an M x N result in row-major tile order
// and reports the size of the current tile.
//
//   for (band = 0; band < ceil(M / ROWS); band++)        // tile rows
//     for (col = 0; col < ceil(N / COLS); col++)         // tile columns
//       tile_m = min(ROWS, rows left), tile_n = min(COLS, columns left)
//
// Every stream of the accelerator (commands, operands, bias, results) owns one
// instance and advances it at its own pace, so the streams stay decoupled.
// m_i and n_i must be stable while valid_o is high.
// -----------------------------------------------------------------------------
module gemm_tile_iter #(
    parameter int ROWS  = 8,
    parameter int COLS  = 8,
    parameter int DIM_W = 16
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      start_i,
    input  logic [DIM_W-1:0]          m_i,
    input  logic [DIM_W-1:0]          n_i,

    input  logic                      next_i,      // advance to the next tile
    output logic                      valid_o,     // a current tile exists
    output logic [$clog2(ROWS+1)-1:0] tile_m_o,
    output logic [$clog2(COLS+1)-1:0] tile_n_o,
    output logic                      col_last_o,  // last tile of its band
    output logic                      last_o       // last tile of the matrix
);

    localparam int MW = $clog2(ROWS + 1);
    localparam int NW = $clog2(COLS + 1);

    logic [DIM_W-1:0] m_rem_q, n_rem_q;   // rows / columns left, current tile included

    // "This is the last tile of its band / the last band" are kept as flags.
    // They are worked out when the remaining counts are written, from the old
    // count (left - step <= step is left <= 2 * step), so that no comparator
    // sits between the counters and the logic that uses the flags.
    logic col_last_q, row_last_q;

    assign col_last_o = col_last_q;
    assign last_o     = col_last_q && row_last_q;

    assign tile_m_o = row_last_q ? m_rem_q[MW-1:0] : MW'(ROWS);
    assign tile_n_o = col_last_q ? n_rem_q[NW-1:0] : NW'(COLS);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_o <= 1'b0;
        end else if (start_i) begin
            valid_o    <= 1'b1;
            m_rem_q    <= m_i;
            n_rem_q    <= n_i;
            row_last_q <= (m_i <= DIM_W'(ROWS));
            col_last_q <= (n_i <= DIM_W'(COLS));
        end else if (next_i && valid_o) begin
            if (last_o) begin
                valid_o <= 1'b0;
            end else if (col_last_q) begin
                n_rem_q    <= n_i;
                col_last_q <= (n_i <= DIM_W'(COLS));
                m_rem_q    <= m_rem_q - DIM_W'(ROWS);
                row_last_q <= (m_rem_q <= DIM_W'(2 * ROWS));
            end else begin
                n_rem_q    <= n_rem_q - DIM_W'(COLS);
                col_last_q <= (n_rem_q <= DIM_W'(2 * COLS));
            end
        end
    end

endmodule
