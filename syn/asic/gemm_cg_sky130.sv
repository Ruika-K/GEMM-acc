// -----------------------------------------------------------------------------
// gemm_cg for sky130: the library's integrated clock gating cell (a latch and
// an AND gate in one cell, characterised as such: clock_gating_integrated_cell
// "latch_posedge"), in place of the behavioural model of rtl/gemm_cg.sv.
// -----------------------------------------------------------------------------
module gemm_cg #(
    parameter bit ENABLE = 1
) (
    input  logic clk_i,
    input  logic en_i,
    output logic gclk_o
);

    if (ENABLE) begin : g_gate
        sky130_fd_sc_hd__dlclkp_4 u_icg (.CLK(clk_i), .GATE(en_i), .GCLK(gclk_o));
    end else begin : g_free
        assign gclk_o = clk_i;
    end

endmodule

// Port list of the cell, as a black box for synthesis.
(* blackbox *)
module sky130_fd_sc_hd__dlclkp_4 (
    input  CLK,
    input  GATE,
    output GCLK
);
endmodule
