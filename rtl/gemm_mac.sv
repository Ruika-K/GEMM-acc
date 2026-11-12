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
// ACC_SEG cuts the carry chain of the accumulator adder. With ACC_SEG = n > 0
// the adder is n-bit segments; the carry out of a segment is not passed on in
// the same cycle but saved in a flip-flop and added to the next segment one
// cycle later. The accumulated value is then the stored sum plus the saved
// carries, each at the bit position where its segment starts. Adding a product
// takes the delay of an n-bit adder whatever ACC_W is. ACC_SEG = 1 is a full
// carry-save accumulator: one layer of full adders, one saved carry per bit.
//
// The saved carries have to be added in once at the end. That is done outside
// the array, where the shift chain leaves it (gemm_cpa), so the shift chain
// carries them along: c_i and c_o are {saved carries, sum}.
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
    parameter int PE_PIPE = 1,   // 1: register between multiplier and adder
    parameter int ACC_SEG = 0,   // 0: plain adder, n: save a carry every n bits
    localparam int NSEG    = (ACC_SEG != 0) ? (ACC_W + ACC_SEG - 1) / ACC_SEG : 1,
    localparam int CHAIN_W = ACC_W + NSEG - 1
) (
    input  logic                     clk,

    input  logic signed [DATA_W-1:0] a_i,
    input  logic signed [DATA_W-1:0] b_i,
    input  logic                     mac_valid_i,  // accumulate the product
    input  logic                     acc_shift_i,  // load c_i instead

    input  logic [CHAIN_W-1:0]       c_i,
    output logic [CHAIN_W-1:0]       c_o
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
    generate
        if (NSEG > 1) begin : g_segmented
            logic [ACC_W-1:0] addend;
            logic [ACC_W-1:0] sum_q, sum_n;
            logic [NSEG-1:1]  car_q, car_n;    // car_q[s]: carry into segment s

            assign addend = {{(ACC_W - PROD_W){mac_prod[PROD_W-1]}}, mac_prod};

            for (genvar g = 0; g < NSEG; g++) begin : g_seg
                localparam int LO = g * ACC_SEG;
                localparam int WD = (ACC_W - LO < ACC_SEG) ? (ACC_W - LO) : ACC_SEG;

                logic        cin;
                logic [WD:0] part;

                if (g == 0) begin : g_cin0
                    assign cin = 1'b0;
                end else begin : g_cin
                    assign cin = car_q[g];
                end

                assign part = {1'b0, sum_q[LO +: WD]} + {1'b0, addend[LO +: WD]}
                            + {{WD{1'b0}}, cin};
                assign sum_n[LO +: WD] = part[WD-1:0];

                // The carry out of the top segment is dropped, which is the
                // same wrap-around as in an ACC_W-bit adder.
                if (g < NSEG - 1) begin : g_cout
                    assign car_n[g+1] = part[WD];
                end else begin : g_top
                    /* verilator lint_off UNUSED */
                    logic unused_carry;
                    /* verilator lint_on UNUSED */
                    assign unused_carry = part[WD];
                end
            end

            always_ff @(posedge clk) begin
                if (acc_shift_i) begin
                    {car_q, sum_q} <= c_i;
                end else if (mac_valid_i) begin
                    sum_q <= sum_n;
                    car_q <= car_n;
                end
            end

            assign c_o = {car_q, sum_q};
        end else begin : g_binary
            logic signed [ACC_W-1:0] acc_q;

            always_ff @(posedge clk) begin
                if (acc_shift_i) begin
                    acc_q <= c_i;
                end else if (mac_valid_i) begin
                    acc_q <= acc_q + {{(ACC_W - PROD_W){mac_prod[PROD_W-1]}}, mac_prod};
                end
            end

            assign c_o = acc_q;
        end
    endgenerate

endmodule
