// -----------------------------------------------------------------------------
// gemm_out: serialises the result rows of gemm_core into one element per beat.
//
// Only the tile_n valid columns of each row are sent. Elements leave in tile
// order: tile by tile (row-major over tiles), row by row inside a tile. TLAST
// marks the last element of the matrix.
// -----------------------------------------------------------------------------
module gemm_out #(
    parameter int ACC_W  = 32,
    parameter int ROWS   = 8,
    parameter int COLS   = 8,
    parameter int DIM_W  = 16,
    parameter int AXIS_W = 32
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       start_i,
    input  logic [DIM_W-1:0]           m_i,
    input  logic [DIM_W-1:0]           n_i,
    output logic                       done_o,      // high while the last element is accepted

    // Result rows from gemm_core
    input  logic                       c_valid_i,
    output logic                       c_ready_o,
    input  logic                       c_last_i,
    input  logic [COLS-1:0][ACC_W-1:0] c_i,

    // Element stream
    output logic                       m_valid_o,
    input  logic                       m_ready_i,
    output logic [AXIS_W-1:0]          m_data_o,
    output logic                       m_last_o
);

    localparam int NW  = $clog2(COLS + 1);
    localparam int CIW = (COLS > 1) ? $clog2(COLS) : 1;

    logic          it_valid, it_last, it_next;
    logic [NW-1:0] tile_n;
    logic [NW-1:0] col_q;
    logic          beat, row_end;

    gemm_tile_iter #(.ROWS(ROWS), .COLS(COLS), .DIM_W(DIM_W)) u_iter (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_i   (start_i),
        .m_i       (m_i),
        .n_i       (n_i),
        .next_i    (it_next),
        .valid_o   (it_valid),
        /* verilator lint_off PINCONNECTEMPTY */
        .tile_m_o  (),
        .tile_n_o  (tile_n),
        .col_last_o(),
        /* verilator lint_on PINCONNECTEMPTY */
        .last_o    (it_last)
    );

    logic signed [ACC_W-1:0] elem;
    assign elem = c_i[col_q[CIW-1:0]];

    assign m_valid_o = c_valid_i && it_valid;
    assign m_data_o  = AXIS_W'(elem);                 // sign extended
    assign row_end   = (col_q == tile_n - 1'b1);
    assign m_last_o  = it_last && c_last_i && row_end;

    assign beat      = m_valid_o && m_ready_i;
    assign c_ready_o = beat && row_end;
    assign it_next   = beat && row_end && c_last_i;
    // Not registered: STATUS must already show DONE to a read that is issued
    // after the host has seen TLAST.
    assign done_o    = beat && m_last_o;

    always_ff @(posedge clk) begin
        if (!rst_n)        col_q <= '0;
        else if (start_i)  col_q <= '0;
        else if (beat)     col_q <= row_end ? '0 : col_q + 1'b1;
    end

endmodule
