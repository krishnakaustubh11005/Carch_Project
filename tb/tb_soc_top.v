`timescale 1ns/1ps
// System test: PicoRV32 runs fw/main.c (built by scripts/build_fw.py into
// FIRMWARE) on soc_top. The firmware does the detailed checking (every C
// value against a software matmul, error codes, ABORT, bus behaviour) and
// talks to this bench only through the result port (protocol in fw/soc.h):
//   0x0000_0001  final: pass
//   0xFttt_iidd  final: failure in test t, case i, detail d
//   0x0000_00B0  marker: bus_error must still be 0; bad accesses follow
//   0xD000_00nn  the next nn words are a benchmark row (printed here)
// Checks (always 5): finished in time with driven outputs, final code is
// pass, no trap, bus_error 0 at the marker, bus_error 1 at the end.
module tb_soc_top;
    parameter FIRMWARE = "sim/build/fw/fw.hex";
    parameter MAX_CYCLES = 5000000;     // default firmware runs ~0.5M; --soc-full raises it

    `include "checks.vh"

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = !clk;

    wire trap, result_valid, bus_error;
    wire [31:0] result;

    soc_top #(.FIRMWARE(FIRMWARE)) dut (
        .clk(clk), .rst(rst), .trap(trap),
        .result(result), .result_valid(result_valid), .bus_error(bus_error)
    );

    integer cycles, bench_left, bench_index;
    reg [31:0] bench [0:6];
    reg finished, driven, marker_seen, marker_ok;
    reg [31:0] final_code;

    task print_bench;
        integer accel;
        begin
            accel = bench[4];
            $display("bench %0dx%0dx%0d: software %0d cycles, accelerator %0d cycles (FETCH %0d + COMPUTE %0d), speed-up %0d.%0dx",
                bench[0], bench[1], bench[2], bench[3], accel, bench[5], bench[6],
                bench[3] / accel, (10 * bench[3] / accel) % 10);
        end
    endtask

    task handle;
        input [31:0] word;
        begin
            if (bench_left > 0) begin
                bench[bench_index] = word;
                bench_index = bench_index + 1;
                bench_left = bench_left - 1;
                if (bench_left == 0)
                    print_bench;
            end else if (word == 32'h0000_0001 || word[31:28] == 4'hF) begin
                finished = 1'b1;
                final_code = word;
            end else if (word == 32'h0000_00B0) begin
                marker_seen = 1'b1;
                marker_ok = (bus_error === 1'b0);
            end else if (word[31:8] == 24'hD0_0000 && word[7:0] == 8'd7) begin
                bench_left = 7;
                bench_index = 0;
            end else begin
                finished = 1'b1;           // unknown word: stop and fail
                final_code = word;
            end
        end
    endtask

    initial begin
        init_checks;
        // Depth 1: bench-level signals only. Raise it (e.g. 3) to see the
        // CPU bus and accelerator inside soc_top; the file grows quickly.
        $dumpfile("sim/vcd/soc_top.vcd");
        $dumpvars(1, tb_soc_top);
        cycles = 0;
        bench_left = 0;
        bench_index = 0;
        finished = 1'b0;
        driven = 1'b1;
        marker_seen = 1'b0;
        marker_ok = 1'b0;
        final_code = 32'hxxxx_xxxx;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        while (!finished && driven && trap !== 1'b1 && cycles < MAX_CYCLES) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if ((result_valid !== 1'b0 && result_valid !== 1'b1)
                    || (trap !== 1'b0 && trap !== 1'b1)
                    || (bus_error !== 1'b0 && bus_error !== 1'b1))
                driven = 1'b0;
            else if (result_valid)
                handle(result);
        end
        $display("stopped after %0d cycles: final code %08h, trap %b, bus_error %b",
            cycles, final_code, trap, bus_error);
        if (final_code[31:28] == 4'hF)
            $display("firmware failure: test %0d, case %0d, detail %0d (see fw/main.c)",
                final_code[27:16], final_code[15:8], final_code[7:0]);

        checks = checks + 1;
        if (!finished || !driven)
            fail_check(!driven ? "soc_top outputs undriven" : "no final result (timeout or trap)");
        checks = checks + 1;
        if (final_code !== 32'h0000_0001)
            fail_check("firmware did not report pass");
        checks = checks + 1;
        if (trap !== 1'b0)
            fail_check("CPU trapped");
        checks = checks + 1;
        if (!marker_seen || !marker_ok)
            fail_check("bus_error set before the deliberate bad accesses (or marker missing)");
        checks = checks + 1;
        if (bus_error !== 1'b1)
            fail_check("bus_error not set by the dropped byte store / unmapped read");
        finish_checks_strict;
    end
endmodule
