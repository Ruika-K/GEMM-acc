// -----------------------------------------------------------------------------
// gemm_fifo: synchronous first-word-fall-through FIFO, any DEPTH >= 1.
//
// There is no full flag. The writer is expected to track free space itself
// (credit-based flow control); pushing into a full FIFO is a design error and
// stops the simulation.
//
// valid_o and data_o come straight from registers. The reader's ready_i
// arrives late in the cycle (it depends on the output handshake), and the
// head of the FIFO feeds the reader's control logic: with data_o read out of
// the storage through a DEPTH:1 multiplexer and valid_o decoded from the
// count, that was a path of 7.5 ns at the slow corner. Here the entry after
// the head is selected from registers ahead of time, and a pop only chooses
// between it and the current head. The head register is a copy of an entry
// of the storage, not an extra entry: the capacity is still DEPTH.
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
    logic [AW-1:0]    wptr_q;
    logic [AW-1:0]    rnext_q;     // the entry after the head
    logic [CW-1:0]    count_q, count_n;
    logic             valid_q;     // count_q >= 1
    logic             more_q;      // count_q >= 2: the entry after the head is stored
    logic [WIDTH-1:0] head_q;      // copy of the oldest entry

    logic pop;

    assign valid_o = valid_q;
    assign data_o  = head_q;
    assign pop     = valid_q && ready_i;

    function automatic logic [AW-1:0] next_ptr(input logic [AW-1:0] ptr);
        next_ptr = (ptr == AW'(DEPTH - 1)) ? {AW{1'b0}} : ptr + 1'b1;
    endfunction

    always_comb begin
        count_n = count_q;
        if (push_i && !pop)      count_n = count_q + 1'b1;
        else if (!push_i && pop) count_n = count_q - 1'b1;
    end

    always_ff @(posedge clk) begin
        if (push_i) mem[wptr_q] <= data_i;
    end

    // New head: after a pop, the next stored entry, or the one being pushed
    // now if there is none; into an empty FIFO, the one being pushed.
    always_ff @(posedge clk) begin
        if (pop)                    head_q <= more_q ? mem[rnext_q] : data_i;
        else if (!valid_q && push_i) head_q <= data_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr_q  <= '0;
            rnext_q <= next_ptr('0);
            count_q <= '0;
            valid_q <= 1'b0;
            more_q  <= 1'b0;
        end else begin
            if (push_i) wptr_q <= next_ptr(wptr_q);
            if (pop) rnext_q <= next_ptr(rnext_q);
            count_q <= count_n;
            valid_q <= (count_n != '0);
            more_q  <= (count_n > CW'(1));
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
