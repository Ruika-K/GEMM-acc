// -----------------------------------------------------------------------------
// gemm_array_bcast: non-systolic baseline, for comparison only.
//
// Same arithmetic as gemm_array (one multiply-accumulate per PE, the same
// optional product register, the same south -> north accumulator chain), but
// operands and control are broadcast instead of forwarded from PE to PE:
//
//   * a_i[i] is registered once and drives all COLS multipliers of row i
//   * b_i[j] is registered once and drives all ROWS multipliers of column j
//   * valid and shift are registered once and drive every PE
//
// There is no skew: all PEs accumulate in the same cycle and all columns
// shift in the same cycle. The cost is fan-out that grows with the array.
// -----------------------------------------------------------------------------
`ifdef GEMM_USE_DSP
(* use_dsp = "yes" *)
`endif
module gemm_array_bcast #(
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int ROWS    = 8,
    parameter int COLS    = 8,
    parameter int PE_PIPE = 1
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        a_valid_i,
    input  logic [ROWS-1:0][DATA_W-1:0] a_i,
    input  logic [COLS-1:0][DATA_W-1:0] b_i,
    input  logic                        shift_i,
    input  logic [COLS-1:0][ACC_W-1:0]  c_i,

    output logic                        c_valid_o,
    output logic [COLS-1:0][ACC_W-1:0]  c_o
);

    localparam int PROD_W = 2 * DATA_W;

    // Edge registers: the only operand / control registers of the design.
    logic                        valid_q, shift_q;
    logic [ROWS-1:0][DATA_W-1:0] a_q;
    logic [COLS-1:0][DATA_W-1:0] b_q;

    always_ff @(posedge clk) begin
        a_q <= a_i;
        b_q <= b_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
            shift_q <= 1'b0;
        end else begin
            valid_q <= a_valid_i;
            shift_q <= shift_i;
        end
    end

    // Controls aligned with the accumulate stage.
    logic mac_valid, acc_shift;

    generate
        if (PE_PIPE != 0) begin : g_ctl_pipe
            logic valid_qq, shift_qq;
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    valid_qq <= 1'b0;
                    shift_qq <= 1'b0;
                end else begin
                    valid_qq <= valid_q;
                    shift_qq <= shift_q;
                end
            end
            assign mac_valid = valid_qq;
            assign acc_shift = shift_qq;
        end else begin : g_ctl_nopipe
            assign mac_valid = valid_q;
            assign acc_shift = shift_q;
        end
    endgenerate

    assign c_valid_o = acc_shift;

    // Accumulators: flat index r * COLS + j, row ROWS is the south edge.
    logic [(ROWS+1)*COLS*ACC_W-1:0] acc;

    generate
        for (genvar j = 0; j < COLS; j++) begin : g_edge
            assign acc[(ROWS*COLS + j)*ACC_W +: ACC_W] = c_i[j];
            assign c_o[j] = acc[j*ACC_W +: ACC_W];
        end

        for (genvar i = 0; i < ROWS; i++) begin : g_row
            for (genvar j = 0; j < COLS; j++) begin : g_col
                logic signed [PROD_W-1:0] a_ext, b_ext, prod, mac_prod;
                logic signed [ACC_W-1:0]  acc_q;

                assign a_ext = {{DATA_W{a_q[i][DATA_W-1]}}, a_q[i]};
                assign b_ext = {{DATA_W{b_q[j][DATA_W-1]}}, b_q[j]};
                assign prod  = a_ext * b_ext;

                if (PE_PIPE != 0) begin : g_pipe
                    logic signed [PROD_W-1:0] prod_q;
                    always_ff @(posedge clk) prod_q <= prod;
                    assign mac_prod = prod_q;
                end else begin : g_nopipe
                    assign mac_prod = prod;
                end

                always_ff @(posedge clk) begin
                    if (acc_shift) begin
                        acc_q <= acc[((i+1)*COLS + j)*ACC_W +: ACC_W];
                    end else if (mac_valid) begin
                        acc_q <= acc_q + {{(ACC_W - PROD_W){mac_prod[PROD_W-1]}}, mac_prod};
                    end
                end

                assign acc[(i*COLS + j)*ACC_W +: ACC_W] = acc_q;
            end
        end
    endgenerate

endmodule
