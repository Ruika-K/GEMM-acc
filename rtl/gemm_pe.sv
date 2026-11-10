// -----------------------------------------------------------------------------
// gemm_pe: one processing element of the output-stationary systolic array.
//
//   * A operands travel west -> east, one PE per cycle, together with a valid.
//   * B operands travel north -> south, one PE per cycle.
//   * The accumulator stays in place and holds one element of C.
//   * A separate "shift" control travels west -> east. While it is high the
//     accumulators of a column form a south -> north shift register, which is
//     used both to drain results and to preload the next addend (D).
//
// Only control registers are reset. Datapath registers (a, b, product,
// accumulator) are initialised by the protocol: every tile starts with a
// shift phase that overwrites the accumulators.
// -----------------------------------------------------------------------------
module gemm_pe #(
    parameter int DATA_W  = 8,   // operand width (signed)
    parameter int ACC_W   = 32,  // accumulator width (signed)
    parameter int PE_PIPE = 1    // 1: register between multiplier and adder
) (
    input  logic                     clk,
    input  logic                     rst_n,      // synchronous, active low

    // A path, west -> east
    input  logic                     a_valid_i,
    input  logic signed [DATA_W-1:0] a_i,
    output logic                     a_valid_o,
    output logic signed [DATA_W-1:0] a_o,

    // B path, north -> south
    input  logic signed [DATA_W-1:0] b_i,
    output logic signed [DATA_W-1:0] b_o,

    // Shift control, west -> east
    input  logic                     shift_i,
    output logic                     shift_o,

    // Accumulator chain, south -> north
    input  logic signed [ACC_W-1:0]  c_i,
    output logic signed [ACC_W-1:0]  c_o
);

    localparam int PROD_W = 2 * DATA_W;

    // ------------------------------------------------------------------
    // Operand forwarding
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        a_o <= a_i;
        b_o <= b_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_valid_o <= 1'b0;
            shift_o   <= 1'b0;
        end else begin
            a_valid_o <= a_valid_i;
            shift_o   <= shift_i;
        end
    end

    // ------------------------------------------------------------------
    // Multiply
    // ------------------------------------------------------------------
    logic signed [PROD_W-1:0] a_ext, b_ext, prod;

    assign a_ext = {{DATA_W{a_i[DATA_W-1]}}, a_i};
    assign b_ext = {{DATA_W{b_i[DATA_W-1]}}, b_i};
    assign prod  = a_ext * b_ext;

    logic                     mac_valid;
    logic signed [PROD_W-1:0] mac_prod;

    generate
        if (PE_PIPE != 0) begin : g_pipe
            logic                     prod_valid_q;
            logic signed [PROD_W-1:0] prod_q;

            always_ff @(posedge clk) begin
                prod_q <= prod;
            end

            always_ff @(posedge clk) begin
                if (!rst_n) prod_valid_q <= 1'b0;
                else        prod_valid_q <= a_valid_i;
            end

            assign mac_valid = prod_valid_q;
            assign mac_prod  = prod_q;
        end else begin : g_nopipe
            assign mac_valid = a_valid_i;
            assign mac_prod  = prod;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Accumulate / shift
    // ------------------------------------------------------------------
    logic signed [ACC_W-1:0] acc_q;

    always_ff @(posedge clk) begin
        if (shift_i) begin
            acc_q <= c_i;
        end else if (mac_valid) begin
            acc_q <= acc_q + {{(ACC_W - PROD_W){mac_prod[PROD_W-1]}}, mac_prod};
        end
    end

    assign c_o = acc_q;

endmodule
