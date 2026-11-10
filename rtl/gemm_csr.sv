// -----------------------------------------------------------------------------
// gemm_csr: AXI4-Lite register block.
//
//   0x00 CTRL    W   [0] START  [1] LOAD_A  [2] LOAD_B  [3] LOAD_BIAS
//                    (write 1 to trigger, reads as 0)
//   0x04 STATUS  R   [0] BUSY   [1] DONE    [2] LOADING [3] ERR
//                W   [3] write 1 to clear ERR
//   0x08 DIM_M   RW  rows of A and C
//   0x0C DIM_K   RW  columns of A, rows of B
//   0x10 DIM_N   RW  columns of B and C
//   0x14 CFG     RW  [0] BIAS_EN
//   0x18 CYCLES  R   clock cycles of the last run, START to last result
//   0x1C INFO    R   [7:0] ROWS [15:8] COLS [23:16] DATA_W [31:24] ACC_W
//
// A CTRL request is only accepted while the block is neither running nor
// loading and the dimensions it needs are in range (1 .. 2^DIM_W - 1, and
// K <= K_MAX). Otherwise it is dropped and ERR is set. DIM_* and CFG are
// write-protected while BUSY or LOADING. DONE is cleared by the next START.
// -----------------------------------------------------------------------------
module gemm_csr #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32,
    parameter int ROWS   = 8,
    parameter int COLS   = 8,
    parameter int DIM_W  = 16,
    parameter int K_MAX  = 1024
) (
    input  logic             clk,
    input  logic             rst_n,

    // AXI4-Lite slave
    input  logic             awvalid_i,
    output logic             awready_o,
    /* verilator lint_off UNUSED */
    input  logic [7:0]       awaddr_i,    // word addressed: bits [1:0] ignored
    /* verilator lint_on UNUSED */
    input  logic             wvalid_i,
    output logic             wready_o,
    input  logic [31:0]      wdata_i,
    input  logic [3:0]       wstrb_i,
    output logic             bvalid_o,
    input  logic             bready_i,
    input  logic             arvalid_i,
    output logic             arready_o,
    /* verilator lint_off UNUSED */
    input  logic [7:0]       araddr_i,
    /* verilator lint_on UNUSED */
    output logic             rvalid_o,
    input  logic             rready_i,
    output logic [31:0]      rdata_o,

    // Configuration
    output logic [DIM_W-1:0] m_o,
    output logic [DIM_W-1:0] k_o,
    output logic [DIM_W-1:0] n_o,
    output logic             bias_en_o,

    // Requests (one-cycle pulses, already checked)
    output logic             start_o,
    output logic             load_a_o,
    output logic             load_b_o,
    output logic             load_bias_o,

    // Events
    input  logic             run_done_i,
    input  logic             load_done_i,
    input  logic             load_err_i,

    output logic             busy_o,
    output logic             done_o
);

    localparam logic [5:0] A_CTRL   = 6'h00;
    localparam logic [5:0] A_STATUS = 6'h01;
    localparam logic [5:0] A_DIM_M  = 6'h02;
    localparam logic [5:0] A_DIM_K  = 6'h03;
    localparam logic [5:0] A_DIM_N  = 6'h04;
    localparam logic [5:0] A_CFG    = 6'h05;
    localparam logic [5:0] A_CYCLES = 6'h06;
    localparam logic [5:0] A_INFO   = 6'h07;

    // ------------------------------------------------------------------
    // Write channel: address and data are captured independently, the write
    // happens once both are present. Ready never depends on valid.
    // ------------------------------------------------------------------
    logic        aw_held_q, w_held_q;
    logic [5:0]  waddr_q;
    logic [31:0] wdata_q;
    logic [3:0]  wstrb_q;
    logic        wr;

    assign awready_o = !aw_held_q;
    assign wready_o  = !w_held_q;
    assign wr        = aw_held_q && w_held_q && !bvalid_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            aw_held_q <= 1'b0;
            w_held_q  <= 1'b0;
            bvalid_o  <= 1'b0;
        end else begin
            if (awvalid_i && awready_o) begin
                aw_held_q <= 1'b1;
                waddr_q   <= awaddr_i[7:2];
            end
            if (wvalid_i && wready_o) begin
                w_held_q <= 1'b1;
                wdata_q  <= wdata_i;
                wstrb_q  <= wstrb_i;
            end
            if (wr) begin
                aw_held_q <= 1'b0;
                w_held_q  <= 1'b0;
                bvalid_o  <= 1'b1;
            end else if (bvalid_o && bready_i) begin
                bvalid_o <= 1'b0;
            end
        end
    end

    // Byte strobes applied to a register value
    function automatic logic [31:0] strobe(input logic [31:0] old);
        for (int b = 0; b < 4; b++) begin
            strobe[b*8 +: 8] = wstrb_q[b] ? wdata_q[b*8 +: 8] : old[b*8 +: 8];
        end
    endfunction

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    logic        loading_q, err_q;
    logic [31:0] cycles_q;
    logic        locked;
    logic [3:0]  ctrl_w;
    logic        dims_run_ok, dims_a_ok, dims_b_ok, dims_bias_ok, k_ok;

    assign locked = busy_o || loading_q;
    assign ctrl_w = wstrb_q[0] ? wdata_q[3:0] : 4'b0000;

    assign k_ok         = (k_o != '0) && (k_o <= DIM_W'(K_MAX));
    assign dims_a_ok    = (m_o != '0) && k_ok;
    assign dims_b_ok    = (n_o != '0) && k_ok;
    assign dims_bias_ok = (n_o != '0);
    assign dims_run_ok  = (m_o != '0) && (n_o != '0) && k_ok;

    logic ctrl_wr, req_start, req_a, req_b, req_bias, req_bad;
    assign ctrl_wr   = wr && (waddr_q == A_CTRL);
    assign req_start = ctrl_wr && ctrl_w[0];
    assign req_a     = ctrl_wr && ctrl_w[1];
    assign req_b     = ctrl_wr && ctrl_w[2];
    assign req_bias  = ctrl_wr && ctrl_w[3];

    // One request at a time, in a legal state, with legal dimensions.
    logic one_hot;
    assign one_hot     = (ctrl_w == 4'b0001) || (ctrl_w == 4'b0010) ||
                         (ctrl_w == 4'b0100) || (ctrl_w == 4'b1000);
    assign start_o     = req_start && one_hot && !locked && dims_run_ok;
    assign load_a_o    = req_a     && one_hot && !locked && dims_a_ok;
    assign load_b_o    = req_b     && one_hot && !locked && dims_b_ok;
    assign load_bias_o = req_bias  && one_hot && !locked && dims_bias_ok;
    assign req_bad     = ctrl_wr && (ctrl_w != 4'b0000) &&
                         !(start_o || load_a_o || load_b_o || load_bias_o);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_o       <= '0;
            k_o       <= '0;
            n_o       <= '0;
            bias_en_o <= 1'b0;
            busy_o    <= 1'b0;
            done_o    <= 1'b0;
            loading_q <= 1'b0;
            err_q     <= 1'b0;
            cycles_q  <= '0;
        end else begin
            if (wr && !locked) begin
                case (waddr_q)
                    A_DIM_M: m_o       <= DIM_W'(strobe(32'(m_o)));
                    A_DIM_K: k_o       <= DIM_W'(strobe(32'(k_o)));
                    A_DIM_N: n_o       <= DIM_W'(strobe(32'(n_o)));
                    A_CFG:   bias_en_o <= wstrb_q[0] ? wdata_q[0] : bias_en_o;
                    default: ;
                endcase
            end

            if (start_o) begin
                busy_o   <= 1'b1;
                done_o   <= 1'b0;
                cycles_q <= '0;
            end else if (busy_o) begin
                cycles_q <= cycles_q + 1'b1;
                if (run_done_i) begin
                    busy_o <= 1'b0;
                    done_o <= 1'b1;
                end
            end

            if (load_a_o || load_b_o || load_bias_o) loading_q <= 1'b1;
            else if (load_done_i)                    loading_q <= 1'b0;

            if (req_bad || load_err_i)                                      err_q <= 1'b1;
            else if (wr && waddr_q == A_STATUS && wstrb_q[0] && wdata_q[3]) err_q <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Read channel
    // ------------------------------------------------------------------
    assign arready_o = !rvalid_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rvalid_o <= 1'b0;
        end else if (arvalid_i && arready_o) begin
            rvalid_o <= 1'b1;
            case (araddr_i[7:2])
                A_STATUS: rdata_o <= {28'd0, err_q, loading_q, done_o, busy_o};
                A_DIM_M:  rdata_o <= 32'(m_o);
                A_DIM_K:  rdata_o <= 32'(k_o);
                A_DIM_N:  rdata_o <= 32'(n_o);
                A_CFG:    rdata_o <= {31'd0, bias_en_o};
                A_CYCLES: rdata_o <= cycles_q;
                A_INFO:   rdata_o <= {8'(ACC_W), 8'(DATA_W), 8'(COLS), 8'(ROWS)};
                default:  rdata_o <= 32'd0;
            endcase
        end else if (rvalid_o && rready_i) begin
            rvalid_o <= 1'b0;
        end
    end

endmodule
