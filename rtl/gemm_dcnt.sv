// -----------------------------------------------------------------------------
// gemm_dcnt: down-counter that only tells when it reaches 1.
//
// For counters whose value nobody reads, only the end: "elements left in this
// row", "rows left in this matrix". A plain W-bit decrement has a borrow
// chain through all W bits; synthesised for sky130 a 16-bit one took 6.5 ns at
// the slow corner, as a chain of OR gates that ABC would not balance.
//
// Here the count is split into a low and a high half, each with a borrow
// chain of half the length:
//
//   * the low half counts down on every decrement;
//   * the high half is kept as hi - 1 (hi_m1_q), decremented when the low
//     half wraps; the high half itself is never needed, only whether it is 0;
//   * "low half is 0", "high half is 0" and "the value is 1" are flags,
//     worked out one decrement ahead.
//
// dec_i, which is usually the late signal, only selects between ready values.
//
// load_i loads value_i (>= 1) and remembers it; reload_i loads the value
// remembered, from registers that hold it already split into halves, so a
// counter that restarts at the same value (elements per row) does not do
// arithmetic on the way. load_i has priority over reload_i, reload_i over
// dec_i. last_o is high while the value is 1. Decrementing at 1 is not
// allowed.
// -----------------------------------------------------------------------------
module gemm_dcnt #(
    parameter int W = 16
) (
    input  logic         clk,
    input  logic         load_i,
    input  logic [W-1:0] value_i,
    input  logic         reload_i,
    input  logic         dec_i,
    output logic         last_o
);

    localparam int LW = (W + 1) / 2;   // low half
    localparam int HW = W - LW;        // high half

    logic [LW-1:0] lo_q;
    logic [HW-1:0] hi_m1_q;        // high half - 1
    logic          lo_zero_q, hi_zero_q, last_q;

    logic [LW-1:0] lo_load;
    logic [HW-1:0] hi_load;

    // The loaded value, split as the counter needs it.
    logic [LW-1:0] lo_init_q;
    logic [HW-1:0] hi_m1_init_q;
    logic          lo_zero_init_q, hi_zero_init_q, last_init_q;

    assign lo_load = value_i[LW-1:0];
    assign hi_load = value_i[W-1:LW];
    assign last_o  = last_q;

    always_ff @(posedge clk) begin
        if (load_i) begin
            lo_q           <= lo_load;
            hi_m1_q        <= hi_load - 1'b1;
            lo_zero_q      <= (lo_load == '0);
            hi_zero_q      <= (hi_load == '0);
            last_q         <= (value_i == W'(1));
            lo_init_q      <= lo_load;
            hi_m1_init_q   <= hi_load - 1'b1;
            lo_zero_init_q <= (lo_load == '0);
            hi_zero_init_q <= (hi_load == '0);
            last_init_q    <= (value_i == W'(1));
        end else if (reload_i) begin
            lo_q      <= lo_init_q;
            hi_m1_q   <= hi_m1_init_q;
            lo_zero_q <= lo_zero_init_q;
            hi_zero_q <= hi_zero_init_q;
            last_q    <= last_init_q;
        end else if (dec_i) begin
            lo_q      <= lo_q - 1'b1;
            lo_zero_q <= (lo_q == LW'(1));
            // value - 1 == 1 needs value == 2: high half 0, low half 2.
            last_q    <= hi_zero_q && (lo_q == LW'(2));
            if (lo_zero_q) begin
                hi_m1_q   <= hi_m1_q - 1'b1;
                hi_zero_q <= (hi_m1_q == '0);
            end
        end
    end

endmodule
