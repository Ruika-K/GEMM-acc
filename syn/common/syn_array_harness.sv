// -----------------------------------------------------------------------------
// syn_array_harness: synthesis-only wrapper around an array.
//
// An array has thousands of port bits, far more than a device has pins. The
// harness feeds every array input from one serial shift register and captures
// every array output into another, so the design has five pins and all array
// paths are register to register. Harness paths are one LUT deep and never
// limit the clock.
//
//   BCAST = 0: gemm_array (systolic)      BCAST = 1: gemm_array_bcast (baseline)
// -----------------------------------------------------------------------------
module syn_array_harness #(
    parameter int BCAST   = 0,
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int ROWS    = 8,
    parameter int COLS    = 8,
    parameter int PE_PIPE = 1,
    parameter int ACC_SEG = 0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic si,       // serial stimulus
    input  logic load,     // 1: capture array outputs, 0: shift them out
    output logic so
);

    localparam int IN_W  = ROWS + ROWS*DATA_W + COLS*DATA_W + 1 + COLS*ACC_W;
    localparam int OUT_W = COLS + COLS*ACC_W;

    logic [IN_W-1:0]  in_q;
    logic [OUT_W-1:0] out_q;

    /* verilator lint_off UNUSED */
    logic [ROWS-1:0]             a_valid;   // the baseline uses a single valid
    /* verilator lint_on UNUSED */
    logic [ROWS-1:0][DATA_W-1:0] a;
    logic [COLS-1:0][DATA_W-1:0] b;
    logic                        shift;
    logic [COLS-1:0][ACC_W-1:0]  c_in;
    logic [COLS-1:0]             c_valid;
    logic [COLS-1:0][ACC_W-1:0]  c_out;

    always_ff @(posedge clk) begin
        in_q <= {in_q[IN_W-2:0], si};
    end

    assign {c_in, shift, b, a, a_valid} = in_q;

    generate
        if (BCAST != 0) begin : g_bcast
            logic c_valid_all;
            gemm_array_bcast #(
                .DATA_W(DATA_W), .ACC_W(ACC_W), .ROWS(ROWS), .COLS(COLS), .PE_PIPE(PE_PIPE),
                .ACC_SEG(ACC_SEG)
            ) u_array (
                .clk      (clk),
                .rst_n    (rst_n),
                .a_valid_i(a_valid[0]),
                .a_i      (a),
                .b_i      (b),
                .shift_i  (shift),
                .c_i      (c_in),
                .c_valid_o(c_valid_all),
                .c_o      (c_out)
            );
            assign c_valid = {COLS{c_valid_all}};
        end else begin : g_systolic
            gemm_array #(
                .DATA_W(DATA_W), .ACC_W(ACC_W), .ROWS(ROWS), .COLS(COLS), .PE_PIPE(PE_PIPE),
                .ACC_SEG(ACC_SEG)
            ) u_array (
                .clk      (clk),
                .rst_n    (rst_n),
                .a_valid_i(a_valid),
                .a_i      (a),
                .b_i      (b),
                .shift_i  (shift),
                .c_i      (c_in),
                .c_valid_o(c_valid),
                .c_o      (c_out)
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (load) out_q <= {c_out, c_valid};
        else      out_q <= {out_q[OUT_W-2:0], 1'b0};
    end

    assign so = out_q[OUT_W-1];

endmodule
