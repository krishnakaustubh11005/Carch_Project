`timescale 1ns/1ps
// Runs a user program (fpga/user/README.md) on fpga_top in Icarus and logs
// every word the ILA would record:  W <clock> <hex>
// Stops one word after the end marker 0xD3000000 (DONE), on a CPU trap
// (TRAP) or after +max_clocks=N system clocks (TIMEOUT). The program image
// comes from fw_path.vh (written by carch_user.py).
module tb_user #(parameter [0:0] ENABLE_ACCEL = 1);
    reg clk125 = 1'b0;
    wire [3:0] led;
    wire uart_tx;
    always #4 clk125 = !clk125;

    fpga_top #(.ENABLE_ACCEL(ENABLE_ACCEL)) dut (.clk125(clk125), .btn0(1'b0), .led(led), .uart_tx(uart_tx));

    integer clocks = 0, max_clocks = 3000000;
    reg seen_end = 1'b0;
    initial if (!$value$plusargs("max_clocks=%d", max_clocks)) max_clocks = 3000000;

    always @(posedge dut.clk) begin
        clocks <= clocks + 1;
        if (dut.dbg_valid) begin
            $display("W %0d %08h", clocks, dut.dbg_result);
            if (seen_end) begin
                $display("DONE %0d", clocks);
                $finish;
            end
            if (dut.dbg_result == 32'hD300_0000)
                seen_end <= 1'b1;
        end
        if (dut.trap === 1'b1) begin
            $display("TRAP %0d", clocks);
            $finish;
        end
        if (clocks >= max_clocks) begin
            $display("TIMEOUT %0d", clocks);
            $finish;
        end
    end
endmodule
