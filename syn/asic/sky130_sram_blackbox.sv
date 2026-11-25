// Port lists of the OpenRAM SRAM macros used by gemm_mem_sky130.sv, as black
// boxes for synthesis. The macros themselves come from the sky130_sram_macros
// library of the PDK (LEF, Liberty, GDS, simulation models).
(* blackbox *)
module sky130_sram_1kbyte_1rw1r_32x256_8 (
    input         clk0, csb0, web0,
    input  [3:0]  wmask0,
    input  [7:0]  addr0,
    input  [31:0] din0,
    output [31:0] dout0,
    input         clk1, csb1,
    input  [7:0]  addr1,
    output [31:0] dout1
);
endmodule

(* blackbox *)
module sky130_sram_2kbyte_1rw1r_32x512_8 (
    input         clk0, csb0, web0,
    input  [3:0]  wmask0,
    input  [8:0]  addr0,
    input  [31:0] din0,
    output [31:0] dout0,
    input         clk1, csb1,
    input  [8:0]  addr1,
    output [31:0] dout1
);
endmodule
