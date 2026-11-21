`timescale 1ns/1ps
// Virtual serial terminal for fpga_top (fpga/README.md). Drives the 125 MHz
// board clock, listens to uart_tx exactly as a PC would, and prints the
// decoded matrices, the benchmark row and PASS/FAIL. Works on the RTL, the
// post-implementation functional netlist and the timing netlist (+SDF).
module tb_fpga_top;
    parameter BIT_NS = 400;             // 2.5 Mbaud (fpga_top BAUD)
    parameter TIMEOUT_US = 20000;

    reg clk125 = 1'b0;
    reg btn0 = 1'b0;
    wire [3:0] led;
    wire uart_tx;

    always #4 clk125 = !clk125;         // 125 MHz

    fpga_top dut (.clk125(clk125), .btn0(btn0), .led(led), .uart_tx(uart_tx));

    // ---------------------------------------------------------------- UART receiver
    task get_byte(output [7:0] b);
        integer i;
        begin
            @(negedge uart_tx);         // start bit
            #(BIT_NS / 2);
            if (uart_tx !== 1'b0)
                $display("[%0t] warning: bad start bit", $time);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                b[i] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1)
                $display("[%0t] warning: bad stop bit", $time);
        end
    endtask

    // One "XXXXXXXX\r\n" line -> 32-bit word.
    task get_word(output [31:0] w);
        reg [7:0] c;
        integer n;
        begin
            n = 0;
            w = 0;
            while (n < 8) begin
                get_byte(c);
                if (c >= "0" && c <= "9") begin w = {w[27:0], c[3:0]}; n = n + 1; end
                else if (c >= "A" && c <= "F") begin w = {w[27:0], c[3:0] + 4'd9}; n = n + 1; end
            end
            c = 0;
            while (c != 8'h0A)
                get_byte(c);
        end
    endtask

    // ---------------------------------------------------------------- protocol
    reg [31:0] tag, rows, cols, w;
    reg [31:0] bench [0:6];
    integer r, col, i, words, last;
    reg signed [7:0] e8;

    initial begin
        $timeformat(-6, 1, " us", 10);
        $display("tb_fpga_top: waiting for the MMCM to lock and the CPU to start...");
        wait (uart_tx === 1'b1);
        forever begin
            get_word(tag);
            if (tag[31:8] == 24'hCA0000) begin
                get_word(rows);
                get_word(cols);
                $display("\n[%t] matrix %s  (%0d x %0d)", $time,
                         tag[7:0] == 8'hA1 ? "A" : tag[7:0] == 8'hB1 ? "B" : "C = A x B",
                         rows, cols);
                if (tag[7:0] == 8'hC4) begin
                    for (r = 0; r < rows; r = r + 1) begin
                        $write("    [");
                        for (col = 0; col < cols; col = col + 1) begin
                            get_word(w);
                            $write(" %6d", $signed(w));
                        end
                        $write(" ]\n");
                    end
                end else begin
                    words = (rows * cols + 3) / 4;
                    for (i = 0; i < words * 4; i = i + 1) begin
                        if (i % 4 == 0)
                            get_word(w);
                        e8 = w[8 * (i % 4) +: 8];
                        if (i < rows * cols) begin
                            if (i % cols == 0) $write("    [");
                            $write(" %4d", e8);
                            if (i % cols == cols - 1) $write(" ]\n");
                        end
                    end
                end
            end else if (tag[31:24] == 8'hD0) begin
                for (i = 0; i < 7; i = i + 1)
                    get_word(bench[i]);
                $display("\n[%t] benchmark  %0dx%0dx%0d", $time, bench[0], bench[1], bench[2]);
                $display("    software (CPU only) : %0d cycles", bench[3]);
                $display("    accelerator         : %0d cycles  (fetch %0d, compute %0d)",
                         bench[4], bench[5], bench[6]);
                $display("    speed-up            : %0d.%0dx", bench[3] / bench[4],
                         (bench[3] * 10 / bench[4]) % 10);
            end else begin
                $display("\n[%t] final result word 0x%08h -> %s   (LEDs = %b)", $time, tag,
                         tag == 32'd1 ? "PASS" : "FAIL", led);
                #(20 * BIT_NS);
                $finish;
            end
        end
    end

    initial begin
        #(TIMEOUT_US * 1000.0);
        $display("TIMEOUT after %0d us (LEDs = %b)", TIMEOUT_US, led);
        $finish;
    end
endmodule
