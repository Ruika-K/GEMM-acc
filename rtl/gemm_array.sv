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
// Shift phase: ROWS shift beats (cycles with shift_i high), not necessarily
// consecutive. A beat presented at cycle s shifts column j in cycle
// s + j + PE_PIPE. In that cycle c_valid_o[j] is high, c_o[j] carries the next
// row of the previous result and c_i[j] must carry the next row of the new
// addend. Row 0 goes first in both directions.
//
// With ACC_SEG > 0 the accumulators keep saved carries (see gemm_mac) and each
// column has a pipelined adder at the north edge that adds them in (gemm_cpa).
// c_valid_o[j] and c_o[j] then appear ceil(ACC_W / CPA_SEG) cycles later;
// everything else is unchanged.
//
// Required spacing (see docs/spec.md), independent of PE_PIPE:
//   first operand slot  >  last shift beat of the preload
//   next shift beat     >= last operand slot + ROWS
// so the minimum tile period is K + 2 * ROWS - 1 cycles.
// -----------------------------------------------------------------------------
module gemm_array #(
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int ROWS    = 8,
    parameter int COLS    = 8,
    parameter int PE_PIPE = 1,
    parameter int ACC_SEG = 0,    // accumulator carry segments, see gemm_mac
    parameter int CPA_SEG = 16    // ACC_SEG > 0: segment width of the final adders
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

    // Width of the shift chain: the accumulator plus its saved carries.
    localparam int NSEG    = (ACC_SEG != 0) ? (ACC_W + ACC_SEG - 1) / ACC_SEG : 1;
    localparam int CHAIN_W = ACC_W + NSEG - 1;

    // Horizontal nets: index [row][col], col = COLS is the unused east edge.
    logic              av [0:ROWS-1][0:COLS];
    logic [DATA_W-1:0] a  [0:ROWS-1][0:COLS];
    logic              sh [0:ROWS-1][0:COLS];

    // Vertical nets: index [row][col], row = ROWS is the south edge.
    logic [DATA_W-1:0] b  [0:ROWS][0:COLS-1];
    logic [CHAIN_W-1:0] c [0:ROWS][0:COLS-1];

    generate
        for (genvar i = 0; i < ROWS; i++) begin : g_west
            assign av[i][0] = a_valid_i[i];
            assign a[i][0]  = a_i[i];
            assign sh[i][0] = shift_i;
        end

        for (genvar j = 0; j < COLS; j++) begin : g_north_south
            assign b[0][j]    = b_i[j];
            // Preload: the value goes into the sum, the saved carries are zero.
            assign c[ROWS][j] = CHAIN_W'(c_i[j]);

            // A column is being drained exactly while its accumulators shift.
            if (NSEG > 1) begin : g_resolve
                // Saved carry s belongs at the bit where segment s starts.
                logic [ACC_W-1:0] carries;
                always_comb begin
                    carries = '0;
                    for (int s = 1; s < NSEG; s++) begin
                        carries[s * ACC_SEG] = c[0][j][ACC_W + s - 1];
                    end
                end

                gemm_cpa #(
                    .W  (ACC_W),
                    .SEG(CPA_SEG)
                ) u_cpa (
                    .clk    (clk),
                    .rst_n  (rst_n),
                    .valid_i(sh[0][j + PE_PIPE]),
                    .a_i    (c[0][j][ACC_W-1:0]),
                    .b_i    (carries),
                    .valid_o(c_valid_o[j]),
                    .sum_o  (c_o[j])
                );
            end else begin : g_direct
                assign c_o[j]       = c[0][j];
                assign c_valid_o[j] = sh[0][j + PE_PIPE];
            end
        end

        for (genvar i = 0; i < ROWS; i++) begin : g_row
            for (genvar j = 0; j < COLS; j++) begin : g_col
                gemm_pe #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W),
                    .PE_PIPE(PE_PIPE),
                    .ACC_SEG(ACC_SEG)
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
