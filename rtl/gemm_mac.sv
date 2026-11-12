// -----------------------------------------------------------------------------
// gemm_mac: multiply-accumulate datapath of one processing element.
//
//   prod = a_i * b_i            (signed, optionally registered: PE_PIPE = 1)
//   acc  = acc_shift_i ? c_i    (shift: drain, and preload of the next addend)
//        : mac_valid_i ? acc + prod
//        : acc
//
// mac_valid_i and acc_shift_i belong to the accumulate stage: with PE_PIPE = 1
// they have to arrive one cycle after the operands they refer to.
//
// The module has no forwarding registers and no reset. It is separate from
// gemm_pe so that the broadcast baseline used for the synthesis comparison
// (syn/common/gemm_array_bcast.sv) is built from exactly the same datapath:
// with hierarchical synthesis both get the same gates, and what remains
// different between them is how operands and control reach the PEs.
//
// The multiplier is left to the synthesis tool. Vivado builds an 8 x 8 bit
// multiplier from LUTs by default; define GEMM_USE_DSP to force DSP blocks.
// -----------------------------------------------------------------------------
`ifdef GEMM_USE_DSP
(* use_dsp = "yes" *)
`endif
module gemm_mac #(
    parameter int DATA_W  = 8,   // operand width (signed)
    parameter int ACC_W   = 32,  // accumulator width (signed)
    parameter int PE_PIPE = 1    // 1: register between multiplier and adder
) (
    input  logic                     clk,

    input  logic signed [DATA_W-1:0] a_i,
    input  logic signed [DATA_W-1:0] b_i,
    input  logic                     mac_valid_i,  // accumulate the product
    input  logic                     acc_shift_i,  // load c_i instead

    input  logic signed [ACC_W-1:0]  c_i,
    output logic signed [ACC_W-1:0]  c_o
);

    localparam int PROD_W = 2 * DATA_W;

    // ------------------------------------------------------------------
    // Multiply
    // ------------------------------------------------------------------
    logic signed [PROD_W-1:0] a_ext, b_ext, prod, mac_prod;

    assign a_ext = {{DATA_W{a_i[DATA_W-1]}}, a_i};
    assign b_ext = {{DATA_W{b_i[DATA_W-1]}}, b_i};
    assign prod  = a_ext * b_ext;

    generate
        if (PE_PIPE != 0) begin : g_pipe
            logic signed [PROD_W-1:0] prod_q;

            always_ff @(posedge clk) begin
                prod_q <= prod;
            end

            assign mac_prod = prod_q;
        end else begin : g_nopipe
            assign mac_prod = prod;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Accumulate / shift
    // ------------------------------------------------------------------
    logic signed [ACC_W-1:0] acc_q;

    always_ff @(posedge clk) begin
        if (acc_shift_i) begin
            acc_q <= c_i;
        end else if (mac_valid_i) begin
            acc_q <= acc_q + {{(ACC_W - PROD_W){mac_prod[PROD_W-1]}}, mac_prod};
        end
    end

    assign c_o = acc_q;

endmodule
