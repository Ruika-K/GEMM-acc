// -----------------------------------------------------------------------------
// gemm_pe_bcast: processing element of the broadcast baseline.
//
// The same multiply, optional product register and accumulator as gemm_pe,
// without the operand and control forwarding registers: operands and controls
// arrive already registered and aligned from gemm_array_bcast. Kept as a
// module of its own so that synthesis treats it exactly like gemm_pe (mapped
// once, instantiated N x N times).
// -----------------------------------------------------------------------------
`ifdef GEMM_USE_DSP
(* use_dsp = "yes" *)
`endif
module gemm_pe_bcast #(
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int PE_PIPE = 1
) (
    input  logic                     clk,

    input  logic signed [DATA_W-1:0] a_i,          // broadcast along the row
    input  logic signed [DATA_W-1:0] b_i,          // broadcast along the column
    input  logic                     mac_valid_i,  // aligned with the accumulate stage
    input  logic                     acc_shift_i,  // aligned with the accumulate stage

    input  logic signed [ACC_W-1:0]  c_i,
    output logic signed [ACC_W-1:0]  c_o
);

    localparam int PROD_W = 2 * DATA_W;

    logic signed [PROD_W-1:0] a_ext, b_ext, prod, mac_prod;

    assign a_ext = {{DATA_W{a_i[DATA_W-1]}}, a_i};
    assign b_ext = {{DATA_W{b_i[DATA_W-1]}}, b_i};
    assign prod  = a_ext * b_ext;

    generate
        if (PE_PIPE != 0) begin : g_pipe
            logic signed [PROD_W-1:0] prod_q;
            always_ff @(posedge clk) prod_q <= prod;
            assign mac_prod = prod_q;
        end else begin : g_nopipe
            assign mac_prod = prod;
        end
    endgenerate

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
