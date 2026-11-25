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
// m_i and n_i must be stable from the cycle before start_i on and while
// valid_o is high (gemm_csr writes them in an earlier register access and
// locks them while the accelerator is busy).
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
    output logic [$clog2(ROWS+1)-1:0] tile_m_last_o,  // tile_m_o - 1
    output logic [$clog2(COLS+1)-1:0] tile_n_last_o,  // tile_n_o - 1
    output logic [$clog2(COLS+1)-1:0] tile_n_last_n_o,  // tile_n_last_o after this cycle
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
    //
    // The tile size and the tile size minus one are registers as well, for
    // the same reason: the streams compare a row or column counter with
    // tile_*_last_o to find the end of a tile, in the same cycle in which
    // that decides whether the iterator advances. All next values below are
    // worked out from registers only; next_i, which arrives late, only
    // chooses between them and the current ones.
    logic col_last_q, row_last_q;
    logic [MW-1:0] tile_m_q, tile_m_last_q;
    logic [NW-1:0] tile_n_q, tile_n_last_q;

    assign col_last_o    = col_last_q;
    assign last_o        = col_last_q && row_last_q;
    assign tile_m_o      = tile_m_q;
    assign tile_n_o      = tile_n_q;
    assign tile_m_last_o = tile_m_last_q;
    assign tile_n_last_o = tile_n_last_q;

    // Size of a tile that starts with `left` rows (columns) to go.
    // (In the last tile `left` is at most ROWS or COLS, so its low bits are it.)
    function automatic logic [MW-1:0] size_m(input logic last, input logic [MW-1:0] left);
        size_m = last ? left : MW'(ROWS);
    endfunction
    function automatic logic [NW-1:0] size_n(input logic last, input logic [NW-1:0] left);
        size_n = last ? left : NW'(COLS);
    endfunction

    // Next band, next tile of the band, first tile of a band.
    logic [DIM_W-1:0] m_next, n_next;
    logic             row_last_next, col_last_next, col_last_first;
    logic [MW-1:0]    tile_m_next;
    logic [NW-1:0]    tile_n_next, tile_n_first;

    assign m_next         = m_rem_q - DIM_W'(ROWS);
    assign row_last_next  = (m_rem_q <= DIM_W'(2 * ROWS));
    assign tile_m_next    = size_m(row_last_next, m_next[MW-1:0]);
    assign n_next         = n_rem_q - DIM_W'(COLS);
    assign col_last_next  = (n_rem_q <= DIM_W'(2 * COLS));
    assign tile_n_next    = size_n(col_last_next, n_next[NW-1:0]);

    // The first tile of the matrix and of every band, worked out from m_i and
    // n_i one cycle ahead. start_i arrives late (it fans out to every
    // iterator and to most of the sequencer) and only selects these.
    logic          row_last_first;
    logic [MW-1:0] tile_m_first, tile_m_first_last;
    logic [NW-1:0] tile_n_first_last;

    always_ff @(posedge clk) begin
        row_last_first    <= (m_i <= DIM_W'(ROWS));
        tile_m_first      <= size_m(m_i <= DIM_W'(ROWS), m_i[MW-1:0]);
        tile_m_first_last <= size_m(m_i <= DIM_W'(ROWS), m_i[MW-1:0]) - 1'b1;
        col_last_first    <= (n_i <= DIM_W'(COLS));
        tile_n_first      <= size_n(n_i <= DIM_W'(COLS), n_i[NW-1:0]);
        tile_n_first_last <= size_n(n_i <= DIM_W'(COLS), n_i[NW-1:0]) - 1'b1;
    end

    // The value tile_n_last_q takes at the next edge, for a stream that keeps
    // its own end-of-row flag as a register (gemm_out).
    always_comb begin
        tile_n_last_n_o = tile_n_last_q;
        if (start_i) begin
            tile_n_last_n_o = tile_n_first_last;
        end else if (next_i && valid_o && !last_o) begin
            tile_n_last_n_o = col_last_q ? tile_n_first_last : tile_n_next - 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_o <= 1'b0;
        end else if (start_i) begin
            valid_o       <= 1'b1;
            m_rem_q       <= m_i;
            n_rem_q       <= n_i;
            row_last_q    <= row_last_first;
            col_last_q    <= col_last_first;
            tile_m_q      <= tile_m_first;
            tile_m_last_q <= tile_m_first_last;
            tile_n_q      <= tile_n_first;
            tile_n_last_q <= tile_n_first_last;
        end else if (next_i && valid_o) begin
            if (last_o) begin
                valid_o <= 1'b0;
            end else if (col_last_q) begin
                n_rem_q       <= n_i;
                col_last_q    <= col_last_first;
                tile_n_q      <= tile_n_first;
                tile_n_last_q <= tile_n_first_last;
                m_rem_q       <= m_next;
                row_last_q    <= row_last_next;
                tile_m_q      <= tile_m_next;
                tile_m_last_q <= tile_m_next - 1'b1;
            end else begin
                n_rem_q       <= n_next;
                col_last_q    <= col_last_next;
                tile_n_q      <= tile_n_next;
                tile_n_last_q <= tile_n_next - 1'b1;
            end
        end
    end

endmodule
