// -----------------------------------------------------------------------------
// gemm_cg: clock gate.
//
// ENABLE = 0: gclk_o is clk_i. ENABLE = 1: gclk_o is clk_i while en_i was high
// before the rising edge, held low otherwise; en_i goes through a latch that
// is open while the clock is low, so a change of en_i in the high phase cannot
// cut a clock pulse short. This is the behaviour of an integrated clock gating
// cell; the ASIC flow uses the library's (syn/asic/gemm_cg_sky130.sv). Not for
// FPGAs, which have clock enables on every flip-flop and gated clock buffers.
// -----------------------------------------------------------------------------
module gemm_cg #(
    parameter bit ENABLE = 1
) (
    input  logic clk_i,
    input  logic en_i,
    output logic gclk_o
);

    if (ENABLE) begin : g_gate
        logic en_l;
        always_latch begin
            if (!clk_i) en_l = en_i;
        end
        assign gclk_o = clk_i & en_l;
    end else begin : g_free
        assign gclk_o = clk_i;
    end

endmodule
