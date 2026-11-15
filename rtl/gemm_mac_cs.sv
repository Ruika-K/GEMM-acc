// -----------------------------------------------------------------------------
// gemm_mac_cs: multiply-accumulate datapath without a carry-propagate adder in
// the multiplier. Same ports and behaviour as gemm_mac; selected with
// MUL_CS = 1 in gemm_pe.
//
// A multiplier is two things: a tree that reduces the partial products to two
// rows, and an adder that turns the two rows into the product. That adder is
// the second carry chain of the PE (the first is in the accumulator, see
// ACC_SEG in gemm_mac). Here it is left out. The two rows go to the
// accumulate stage as they are, where one more layer of full adders merges
// them with the accumulator; what remains to be added is two rows again, and
// that addition is the segmented one of gemm_mac, with saved carries.
//
//   stage 1   partial products -> 3:2 compressor tree -> two rows  [register]
//   stage 2   accumulator + two rows -> 3:2 -> segmented add -> accumulator
//
// Partial products are Baugh-Wooley: the products that involve exactly one
// sign bit are inverted, and the constant -2^(2W-1) + 2^W makes up for it
// (W = DATA_W). 2^W goes into a free position of the first row. The rows then
// add up to product + 2^(2W-1), which is never negative and fits in 2W bits,
// so no row needs sign extension inside the tree. The remaining -2^(2W-1) is
// ones from bit 2W-1 upwards; added to the top bits of the two rows it gives
// the two ACC_W-bit rows the accumulate stage needs:
//
//   x = { 1 ... 1,  ~(s ^ c),  s[2W-2:0] }      s, c: bit 2W-1 of the two rows
//   y = { 0 ... 0,  (s | c), 0,  c[2W-2:0] }    (s | c) sits at bit 2W
//
// x + y is the sign-extended product modulo 2^ACC_W.
// -----------------------------------------------------------------------------
module gemm_mac_cs #(
    parameter int DATA_W  = 8,   // operand width (signed)
    parameter int ACC_W   = 32,  // accumulator width (signed), > 2 * DATA_W
    parameter int PE_PIPE = 1,   // 1: register between the tree and the accumulate stage
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
    // Shape of the compressor tree: every level turns each group of three
    // rows into two and passes the one or two left over.
    // ------------------------------------------------------------------
    function automatic integer rows_at(input integer level);
        integer n, l;
        begin
            n = DATA_W;
            for (l = 0; l < level; l = l + 1) begin
                n = 2 * (n / 3) + (n % 3);
            end
            rows_at = n;
        end
    endfunction

    function automatic integer tree_levels(input integer first);
        integer n, l, i;
        begin
            n = first;
            l = 0;
            for (i = 0; i < 2 * first; i = i + 1) begin
                if (n > 2) begin
                    n = 2 * (n / 3) + (n % 3);
                    l = l + 1;
                end
            end
            tree_levels = l;
        end
    endfunction

    localparam int LEVELS = tree_levels(DATA_W);

    // row[l][r]: row r at the input of level l; row[LEVELS] is the result.
    // Level l + 1 is computed from level l of the same array, which a linter
    // that looks at the array as a whole takes for a combinational loop. The
    // warning is switched off up to the end of the tree.
    /* verilator lint_off UNOPTFLAT */
    logic [PROD_W-1:0] row [0:LEVELS][0:DATA_W-1];

    // ------------------------------------------------------------------
    // Partial products
    // ------------------------------------------------------------------
    generate
        for (genvar j = 0; j < DATA_W; j++) begin : g_pp
            for (genvar p = 0; p < PROD_W; p++) begin : g_bit
                if (p >= j && p < j + DATA_W) begin : g_and
                    // Inverted when exactly one of the two bits is a sign bit.
                    localparam bit INV = ((p - j) == DATA_W - 1) != (j == DATA_W - 1);
                    assign row[0][j][p] = (a_i[p-j] & b_i[j]) ^ INV;
                end else if (j == 0 && p == DATA_W) begin : g_const
                    assign row[0][j][p] = 1'b1;
                end else begin : g_zero
                    assign row[0][j][p] = 1'b0;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Compressor tree
    // ------------------------------------------------------------------
    generate
        for (genvar l = 0; l < LEVELS; l++) begin : g_level
            localparam int N = rows_at(l);

            for (genvar t = 0; t < N / 3; t++) begin : g_csa
                logic [PROD_W-1:0] x, y, z;
                logic [PROD_W-2:0] maj;

                assign x   = row[l][3*t];
                assign y   = row[l][3*t+1];
                assign z   = row[l][3*t+2];
                assign maj = (x[PROD_W-2:0] & y[PROD_W-2:0])
                           | (x[PROD_W-2:0] & z[PROD_W-2:0])
                           | (y[PROD_W-2:0] & z[PROD_W-2:0]);

                // The rows add up to less than 2^PROD_W, so nothing is lost
                // when the carry row is cut off at the top.
                assign row[l+1][2*t]   = x ^ y ^ z;
                assign row[l+1][2*t+1] = {maj, 1'b0};
            end

            for (genvar t = 0; t < N % 3; t++) begin : g_pass
                assign row[l+1][2*(N/3) + t] = row[l][3*(N/3) + t];
            end

            for (genvar t = 2 * (N / 3) + (N % 3); t < DATA_W; t++) begin : g_unused
                assign row[l+1][t] = '0;
            end
        end
    endgenerate

    /* verilator lint_on UNOPTFLAT */

    // The two rows, with the top bit of each replaced as described above.
    logic [PROD_W-1:0] mx, my;      // stage 1 result
    logic [PROD_W-1:0] ax, ay;      // the same at the accumulate stage

    assign mx = {~(row[LEVELS][0][PROD_W-1] ^ row[LEVELS][1][PROD_W-1]),
                 row[LEVELS][0][PROD_W-2:0]};
    assign my = { (row[LEVELS][0][PROD_W-1] | row[LEVELS][1][PROD_W-1]),
                 row[LEVELS][1][PROD_W-2:0]};

    generate
        if (PE_PIPE != 0) begin : g_pipe
            logic [PROD_W-1:0] mx_q, my_q;

            always_ff @(posedge clk) begin
                mx_q <= mx;
                my_q <= my;
            end

            assign ax = mx_q;
            assign ay = my_q;
        end else begin : g_nopipe
            assign ax = mx;
            assign ay = my;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Accumulate / shift
    // ------------------------------------------------------------------
    logic [ACC_W-1:0] add_x, add_y;     // add_x + add_y = sign-extended product
    logic [ACC_W-1:0] sum_q, sum_n;
    logic [ACC_W-1:0] op_x, op_y, maj;  // accumulator + product as two rows

    assign add_x = {{(ACC_W - PROD_W){1'b1}}, ax};
    assign add_y = {{(ACC_W - PROD_W - 1){1'b0}}, ay[PROD_W-1], 1'b0, ay[PROD_W-2:0]};

    // 3:2 compressor: sum_q + add_x + add_y = op_x + op_y. The carry out of
    // the top bit is dropped, the same wrap-around as in an ACC_W-bit adder.
    assign maj  = (sum_q & add_x) | (sum_q & add_y) | (add_x & add_y);
    assign op_x = sum_q ^ add_x ^ add_y;
    assign op_y = {maj[ACC_W-2:0], 1'b0};

    generate
        if (NSEG > 1) begin : g_segmented
            logic [NSEG-1:1] car_q, car_n;    // car_q[s]: carry into segment s

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

                assign part = {1'b0, op_x[LO +: WD]} + {1'b0, op_y[LO +: WD]}
                            + {{WD{1'b0}}, cin};
                assign sum_n[LO +: WD] = part[WD-1:0];

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
            assign sum_n = op_x + op_y;

            always_ff @(posedge clk) begin
                if (acc_shift_i) begin
                    sum_q <= c_i;
                end else if (mac_valid_i) begin
                    sum_q <= sum_n;
                end
            end

            assign c_o = sum_q;
        end
    endgenerate

    /* verilator lint_off UNUSED */
    logic unused_maj;
    /* verilator lint_on UNUSED */
    assign unused_maj = maj[ACC_W-1];

endmodule
