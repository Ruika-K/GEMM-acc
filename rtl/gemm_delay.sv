// -----------------------------------------------------------------------------
// gemm_delay: fixed delay line, STAGES cycles (0 = wire).
//
// With RESET = 0 the registers have no reset, which lets FPGA tools map the
// line onto shift-register LUTs. Use RESET = 1 only for control bits that must
// be idle after reset.
// -----------------------------------------------------------------------------
module gemm_delay #(
    parameter int WIDTH  = 8,
    parameter int STAGES = 1,
    parameter int RESET  = 0
) (
    /* verilator lint_off UNUSED */
    input  logic             clk,     // unused when STAGES = 0
    input  logic             rst_n,   // unused when RESET = 0
    /* verilator lint_on UNUSED */
    input  logic [WIDTH-1:0] d_i,
    output logic [WIDTH-1:0] q_o
);

    generate
        if (STAGES == 0) begin : g_wire
            assign q_o = d_i;
        end else begin : g_line
            logic [WIDTH-1:0] sr [0:STAGES-1];

            always_ff @(posedge clk) begin
                if (RESET != 0 && !rst_n) begin
                    for (int s = 0; s < STAGES; s++) sr[s] <= '0;
                end else begin
                    sr[0] <= d_i;
                    for (int s = 1; s < STAGES; s++) sr[s] <= sr[s-1];
                end
            end

            assign q_o = sr[STAGES-1];
        end
    endgenerate

endmodule
