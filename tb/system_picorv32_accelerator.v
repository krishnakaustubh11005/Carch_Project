`timescale 1ns/1ps
// System test is built by scripts/run_processor.py, not module discovery.
module system_picorv32_accelerator;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    wire trap, valid;
    wire [31:0] addr, wdata;
    wire [3:0] wstrb;
    reg ready = 0;
    reg [31:0] rdata = 0;
    reg [31:0] memory [0:16383];
    reg [8191:0] firmware;
    integer i, cases = 0, expected_cases;
    reg waiting_accel = 0;
    reg [31:0] cpu_cycles;

    picorv32_accelerator dut (
        .clk(clk), .rst(rst), .trap(trap), .ram_valid(valid),
        .ram_addr(addr), .ram_wdata(wdata), .ram_wstrb(wstrb),
        .ram_ready(ready), .ram_rdata(rdata)
    );

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/vcd/processor_accelerator.vcd");
            $dumpvars(1, system_picorv32_accelerator);
        end
        if (!$value$plusargs("FIRMWARE=%s", firmware) ||
            !$value$plusargs("CASES=%d", expected_cases) || expected_cases < 1)
            $fatal(1, "TEST FAILED: missing firmware/case count");
        for (i = 0; i < 16384; i = i + 1) memory[i] = 0;
        $readmemh(firmware, memory);
        repeat (10) @(negedge clk);
        rst = 0;
        repeat (2000000) @(posedge clk);
        $fatal(1, "TEST FAILED: processor timeout");
    end

    integer byte_lane;
    always @(posedge clk) begin
        ready <= 0;
        if (!rst && trap) $fatal(1, "TEST FAILED: unexpected CPU trap");
        if (!rst && valid && !ready) begin
            ready <= 1;
            if (addr < 65536) begin
                rdata <= memory[addr >> 2];
                for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                    if (wstrb[byte_lane])
                        memory[addr >> 2][8*byte_lane +: 8] <= wdata[8*byte_lane +: 8];
            end else if (addr == 32'h20000000 && wstrb == 15) begin
                if (waiting_accel || wdata == 0) $fatal(1, "TEST FAILED: CPU report sequence");
                cpu_cycles <= wdata;
                waiting_accel <= 1;
            end else if (addr == 32'h20000004 && wstrb == 15) begin
                if (!waiting_accel || wdata == 0) $fatal(1, "TEST FAILED: accelerator report sequence");
                $display("CASE %0d PASS cpu_cycles=%0d accelerator_total_cycles=%0d", cases, cpu_cycles, wdata);
                cases <= cases + 1;
                waiting_accel <= 0;
            end else if (addr == 32'h20000008 && wstrb == 15) begin
                if (wdata != 1 || waiting_accel || cases != expected_cases)
                    $fatal(1, "TEST FAILED: firmware status=%0d cases=%0d", wdata, cases);
                $display("PROCESSOR PASS cases=%0d checks=%0d", cases, cases*32);
                $display("TEST PASSED");
                $finish;
            end else $fatal(1, "TEST FAILED: invalid external memory access %h", addr);
        end
    end
endmodule
