// -----------------------------------------------------------------------------
// gemm_cpa: pipelined carry-propagate adder, sum_o = a_i + b_i (mod 2^W).
//
// Used once per column at the north edge of the array when the accumulators
// keep saved carries (ACC_SEG > 0, see gemm_mac): it adds the carries that
// leave the shift chain to the sum and so turns the pair into an ordinary
// number.
//
// The addition is cut into segments of SEG bits, one segment per cycle, lowest
// first; the carry out of a segment is registered and enters the next one a
// cycle later. Latency is ceil(W / SEG) cycles and the longest path is a
// SEG-bit adder, so this adder never limits the clock however wide the
// accumulator is. valid_i travels with the data.
// -----------------------------------------------------------------------------
module gemm_cpa #(
    parameter int W   = 32,
    parameter int SEG = 16
) (
    input  logic         clk,
    input  logic         rst_n,     // synchronous, active low

    input  logic         valid_i,
    input  logic [W-1:0] a_i,
    input  logic [W-1:0] b_i,

    output logic         valid_o,
    output logic [W-1:0] sum_o
);

    localparam int NS = (W + SEG - 1) / SEG;   // stages

    // Stage inputs (_s) and stage registers (_q). Stage k adds segment k.
    // Bits a stage no longer needs are still carried along here; synthesis
    // removes the registers nothing reads.
    // The carry out of the last stage is dropped.
    /* verilator lint_off UNUSED */
    logic [NS-1:0][W-1:0] a_s, b_s, s_s;
    logic [NS-1:0][W-1:0] a_q, b_q, s_q;
    logic [NS-1:0]        cy_q;
    /* verilator lint_on UNUSED */
    logic [NS-1:0]        cy_s, v_s;
    logic [NS-1:0]        v_q;

    generate
        for (genvar k = 0; k < NS; k++) begin : g_stage
            localparam int LO = k * SEG;
            localparam int WD = (W - LO < SEG) ? (W - LO) : SEG;

            if (k == 0) begin : g_first
                assign a_s[k]  = a_i;
                assign b_s[k]  = b_i;
                assign s_s[k]  = '0;
                assign cy_s[k] = 1'b0;
                assign v_s[k]  = valid_i;
            end else begin : g_next
                assign a_s[k]  = a_q[k-1];
                assign b_s[k]  = b_q[k-1];
                assign s_s[k]  = s_q[k-1];
                assign cy_s[k] = cy_q[k-1];
                assign v_s[k]  = v_q[k-1];
            end

            logic [WD:0] part;
            assign part = {1'b0, a_s[k][LO +: WD]} + {1'b0, b_s[k][LO +: WD]}
                        + {{WD{1'b0}}, cy_s[k]};

            always_ff @(posedge clk) begin
                a_q[k]           <= a_s[k];
                b_q[k]           <= b_s[k];
                s_q[k]           <= s_s[k];
                s_q[k][LO +: WD] <= part[WD-1:0];
                cy_q[k]          <= part[WD];
            end

            always_ff @(posedge clk) begin
                if (!rst_n) v_q[k] <= 1'b0;
                else        v_q[k] <= v_s[k];
            end
        end
    endgenerate

    assign sum_o   = s_q[NS-1];
    assign valid_o = v_q[NS-1];

endmodule
