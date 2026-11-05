`timescale 1ns/1ps
module testbench;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0;
    wire trap, valid;
    wire [31:0] addr, wdata;
    wire [3:0] wstrb;
    reg ready = 0;
    reg [31:0] rdata = 0;
    reg [31:0] memory [0:16383];
    integer i, reports = 0;
    reg [1023:0] firmware;
    initial begin
        for (i = 0; i < 16384; i = i + 1) memory[i] = 0;
        if (!$value$plusargs("firmware=%s", firmware)) $fatal(1, "Missing firmware");
        $readmemh(firmware, memory);
        repeat (10) @(negedge clk);
        resetn = 1;
        repeat (10000000) @(posedge clk);
        $fatal(1, "CPU timeout");
    end
    picorv32 #(.ENABLE_MUL(1), .ENABLE_DIV(1), .STACKADDR(65536)) cpu (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_valid(valid), .mem_addr(addr), .mem_wdata(wdata),
        .mem_wstrb(wstrb), .mem_ready(ready), .mem_rdata(rdata),
        .irq(32'b0), .pcpi_wr(1'b0), .pcpi_rd(32'b0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );
    always @(posedge clk) begin
        ready <= 0;
        if (resetn && trap) $fatal(1, "Unexpected CPU trap");
        if (resetn && valid && !ready) begin
            ready <= 1;
            if (addr < 65536) begin
                rdata <= memory[addr >> 2];
                for (integer b = 0; b < 4; b = b + 1)
                    if (wstrb[b]) memory[addr >> 2][8*b +: 8] <= wdata[8*b +: 8];
            end else if (addr == 32'h10000000 && wstrb == 4'b1111) begin
                $display("CASE %0d PASS cycles=%0d", reports, wdata);
                reports = reports + 1;
            end else if (addr == 32'h10000004 && wstrb == 4'b1111) begin
                if (wdata != 1) $fatal(1, "Firmware mismatch/status=%0d", wdata);
                $display("CPU PASS cases=%0d", reports);
                $finish;
            end else $fatal(1, "Invalid memory access %h", addr);
        end
    end
endmodule
