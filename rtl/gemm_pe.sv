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
// With PE_PIPE = 1 the accumulator sits one pipeline stage behind the
// multiplier, so the shift control is taken one stage later as well (from the
// forwarding register). Seen from outside, operands and shift control then
// have the same latency to the accumulator and the phase spacing rules do not
// depend on PE_PIPE.
//
// Only control registers are reset. Datapath registers (a, b, product,
// accumulator) are initialised by the protocol: every tile starts with a
// shift phase that overwrites the accumulators.
//
// The PE is the forwarding registers and the control alignment; the multiply-
// accumulate datapath itself is gemm_mac.
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
    // Control for the accumulate stage
    // ------------------------------------------------------------------
    // With the product register the accumulator works one cycle behind the
    // operands, so its controls are the forwarded (registered) ones.
    logic mac_valid;
    logic acc_shift;

    generate
        if (PE_PIPE != 0) begin : g_pipe
            assign mac_valid = a_valid_o;
            assign acc_shift = shift_o;
        end else begin : g_nopipe
            assign mac_valid = a_valid_i;
            assign acc_shift = shift_i;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Multiply-accumulate
    // ------------------------------------------------------------------
    gemm_mac #(
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W),
        .PE_PIPE(PE_PIPE)
    ) u_mac (
        .clk        (clk),
        .a_i        (a_i),
        .b_i        (b_i),
        .mac_valid_i(mac_valid),
        .acc_shift_i(acc_shift),
        .c_i        (c_i),
        .c_o        (c_o)
    );

endmodule
