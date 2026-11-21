// PYNQ-Z2 board wrapper around the unchanged soc_top (fpga/README.md).
//
//   clk125 (board, 125 MHz) -> MMCM -> clk (1000 MHz VCO / CLK_DIV = 50 MHz)
//   reset: held while the MMCM is unlocked, BTN0 is pressed, or for 16 clocks
//          after both clear; synchronised to clk
//   soc_top: PicoRV32 + 64 KB RAM (firmware preloaded) + accelerator
//   uart_result_bridge: every result-port word -> "XXXXXXXX\r\n" on uart_tx
//   ILA taps: dbg_result / dbg_valid (see build.tcl, hw.tcl)
//   LEDs: 0 heartbeat, 1 PASS (last word was 1), 2 FAIL/trap/bus error,
//         3 bridge FIFO overflow
//
// Firmware: path of the $readmemh image, from fw_path.vh (written by
// build.tcl / sim.tcl) so the path is absolute on any machine.
`include "fw_path.vh"

module fpga_top #(
    parameter CLK_DIV = 20,             // 20 -> 50 MHz, 40 -> 25 MHz
    parameter BAUD = 2500000            // exact at 50 and 25 MHz (20 / 10 clocks per bit)
) (
    input  wire clk125,
    input  wire btn0,                   // active high
    output wire [3:0] led,
    output wire uart_tx
);
    localparam CLK_HZ = 1000000000 / CLK_DIV;

    // ---------------------------------------------------------------- clock
    wire clk_mmcm, clk_fb, locked, clk;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(8.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(8.0),          // 125 MHz x 8 = 1000 MHz VCO
        .CLKOUT0_DIVIDE_F(CLK_DIV)
    ) u_mmcm (
        .CLKIN1(clk125), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
        .CLKOUT0(clk_mmcm), .LOCKED(locked), .RST(1'b0), .PWRDWN(1'b0),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
        .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );
    BUFG u_bufg (.I(clk_mmcm), .O(clk));

    // ---------------------------------------------------------------- reset
    (* ASYNC_REG = "TRUE" *) reg [1:0] locked_s = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_s = 2'b00;
    reg [4:0] por = 5'd0;
    reg rst = 1'b1;

    always @(posedge clk) begin
        locked_s <= {locked_s[0], locked};
        btn_s <= {btn_s[0], btn0};
        if (!locked_s[1] || btn_s[1])
            por <= 5'd0;
        else if (!por[4])
            por <= por + 5'd1;
        rst <= !por[4];
    end

    // ---------------------------------------------------------------- SoC
    wire trap, result_valid, bus_error;
    wire [31:0] result;

    soc_top #(.FIRMWARE(`FPGA_FIRMWARE)) u_soc (
        .clk(clk), .rst(rst), .trap(trap),
        .result(result), .result_valid(result_valid), .bus_error(bus_error)
    );

    // ---------------------------------------------------------------- ILA taps
    // Registered copies of the result port, kept by mark_debug so build.tcl
    // can hook the ILA to them (read back over JTAG by hw.tcl).
    (* mark_debug = "true" *) reg [31:0] dbg_result = 32'd0;
    (* mark_debug = "true" *) reg dbg_valid = 1'b0;
    always @(posedge clk) begin
        dbg_result <= result;
        dbg_valid <= result_valid;
    end

    // ---------------------------------------------------------------- outputs
    wire overflow;

    uart_result_bridge #(.CLKS_PER_BIT(CLK_HZ / BAUD)) u_bridge (
        .clk(clk), .rst(rst), .valid(result_valid), .word(result),
        .tx(uart_tx), .overflow(overflow)
    );

    reg [25:0] beat = 26'd0;
    always @(posedge clk)
        beat <= beat + 26'd1;

    assign led[0] = beat[25];
    assign led[1] = (result == 32'd1);
    assign led[2] = (result[31:28] == 4'hF) || trap || bus_error;
    assign led[3] = overflow;
endmodule
