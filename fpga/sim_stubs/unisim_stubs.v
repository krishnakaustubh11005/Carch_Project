`timescale 1ns/1ps
// Behavioural stand-ins for MMCME2_BASE and BUFG so the RTL can be checked
// with Icarus (make fpga-rtl-sim) where the Xilinx UNISIM library is absent.
// Vivado uses the real primitives; never add this file to a Vivado build.
module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD = 8.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 8.0,
    parameter real CLKOUT0_DIVIDE_F = 20.0
) (
    input CLKIN1, input CLKFBIN, input RST, input PWRDWN,
    output CLKFBOUT, output CLKFBOUTB,
    output reg CLKOUT0 = 1'b0, output CLKOUT0B, output CLKOUT1, output CLKOUT1B,
    output CLKOUT2, output CLKOUT2B, output CLKOUT3, output CLKOUT3B,
    output CLKOUT4, output CLKOUT5, output CLKOUT6,
    output reg LOCKED = 1'b0
);
    real half;
    initial begin
        half = CLKIN1_PERIOD * DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F / 2.0;
        #500 LOCKED = 1'b1;
    end
    always #(half) CLKOUT0 = !CLKOUT0;
    assign CLKFBOUT = CLKIN1;
endmodule

module BUFG (input I, output O);
    assign O = I;
endmodule
