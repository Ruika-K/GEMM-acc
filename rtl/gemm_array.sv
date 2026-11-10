// -----------------------------------------------------------------------------
// gemm_array: ROWS x COLS mesh of gemm_pe.
//
//                 b_i[0]   b_i[1]  ...          c_o[j], c_valid_o[j]
//                   |        |                        ^
//                   v        v                        |
//   a_i[0]  --> [PE 0,0]-->[PE 0,1]--> ...       (north edge)
//   a_i[1]  --> [PE 1,0]-->[PE 1,1]--> ...
//     ...           |        |
//   shift_i --> (every row, west edge)           c_i[j] enters at the south edge
//
// The array itself contains no skew logic. The surrounding logic must present
//   A[i][k] on a_i[i] at cycle t0 + i + k   (row i delayed by i cycles)
//   B[k][j] on b_i[j] at cycle t0 + j + k   (column j delayed by j cycles)
// so that both operands of A[i][k] * B[k][j] meet in PE(i, j).
//
// Shift phase: hold shift_i high for ROWS cycles starting at cycle ts.
// Column j shifts during cycles ts + j .. ts + j + ROWS - 1. In cycle
// ts + j + r, c_o[j] carries row r of the previous result and c_i[j] must
// carry row r of the next addend.
//
// Required spacing (see docs/spec.md):
//   t0      >= ts + ROWS - PE_PIPE
//   ts_next >= t0 + K + ROWS - 1 + PE_PIPE
// so the minimum tile period is K + 2 * ROWS - 1 cycles for either PE_PIPE.
// -----------------------------------------------------------------------------
module gemm_array #(
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int ROWS    = 8,
    parameter int COLS    = 8,
    parameter int PE_PIPE = 1
) (
    input  logic                             clk,
    input  logic                             rst_n,

    // West edge: one A element (and its valid) per row
    input  logic        [ROWS-1:0]             a_valid_i,
    input  logic        [ROWS-1:0][DATA_W-1:0] a_i,

    // North edge: one B element per column
    input  logic        [COLS-1:0][DATA_W-1:0] b_i,

    // Shift control, shared by all rows at the west edge
    input  logic                               shift_i,

    // South edge: preload values, one per column
    input  logic        [COLS-1:0][ACC_W-1:0]  c_i,

    // North edge: drained results, one per column
    output logic        [COLS-1:0]             c_valid_o,
    output logic        [COLS-1:0][ACC_W-1:0]  c_o
);

    // Horizontal nets: index [row][col], col = COLS is the unused east edge.
    logic              av [0:ROWS-1][0:COLS];
    logic [DATA_W-1:0] a  [0:ROWS-1][0:COLS];
    logic              sh [0:ROWS-1][0:COLS];

    // Vertical nets: index [row][col], row = ROWS is the south edge.
    logic [DATA_W-1:0] b  [0:ROWS][0:COLS-1];
    logic [ACC_W-1:0]  c  [0:ROWS][0:COLS-1];

    generate
        for (genvar i = 0; i < ROWS; i++) begin : g_west
            assign av[i][0] = a_valid_i[i];
            assign a[i][0]  = a_i[i];
            assign sh[i][0] = shift_i;
        end

        for (genvar j = 0; j < COLS; j++) begin : g_north_south
            assign b[0][j]      = b_i[j];
            assign c[ROWS][j]   = c_i[j];
            assign c_o[j]       = c[0][j];
            // A column is being drained exactly while its shift control is high.
            assign c_valid_o[j] = sh[0][j];
        end

        for (genvar i = 0; i < ROWS; i++) begin : g_row
            for (genvar j = 0; j < COLS; j++) begin : g_col
                gemm_pe #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W),
                    .PE_PIPE(PE_PIPE)
                ) u_pe (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .a_valid_i(av[i][j]),
                    .a_i      (a[i][j]),
                    .a_valid_o(av[i][j+1]),
                    .a_o      (a[i][j+1]),
                    .b_i      (b[i][j]),
                    .b_o      (b[i+1][j]),
                    .shift_i  (sh[i][j]),
                    .shift_o  (sh[i][j+1]),
                    .c_i      (c[i+1][j]),
                    .c_o      (c[i][j])
                );
            end
        end
    endgenerate

endmodule
