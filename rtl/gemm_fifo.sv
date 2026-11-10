// -----------------------------------------------------------------------------
// gemm_fifo: synchronous first-word-fall-through FIFO, any DEPTH >= 1.
//
// There is no full flag. The writer is expected to track free space itself
// (credit-based flow control); pushing into a full FIFO is a design error and
// stops the simulation.
// -----------------------------------------------------------------------------
module gemm_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             push_i,
    input  logic [WIDTH-1:0] data_i,

    output logic             valid_o,
    input  logic             ready_i,
    output logic [WIDTH-1:0] data_o
);

    localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int CW = $clog2(DEPTH + 1);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]    wptr_q, rptr_q;
    logic [CW-1:0]    count_q;

    logic pop;
    assign valid_o = (count_q != '0);
    assign pop     = valid_o && ready_i;
    assign data_o  = mem[rptr_q];

    function automatic logic [AW-1:0] next_ptr(input logic [AW-1:0] ptr);
        return (ptr == AW'(DEPTH - 1)) ? '0 : ptr + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (push_i) mem[wptr_q] <= data_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr_q  <= '0;
            rptr_q  <= '0;
            count_q <= '0;
        end else begin
            if (push_i) wptr_q <= next_ptr(wptr_q);
            if (pop)    rptr_q <= next_ptr(rptr_q);
            if (push_i && !pop)      count_q <= count_q + 1'b1;
            else if (!push_i && pop) count_q <= count_q - 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && push_i && !pop && count_q == CW'(DEPTH)) begin
            $fatal(1, "gemm_fifo: push into a full FIFO");
        end
    end
`endif

endmodule
