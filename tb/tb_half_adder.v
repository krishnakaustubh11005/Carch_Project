`timescale 1ns/1ps
module tb_half_adder;
    reg a, b;
    wire sum, carry;
    reg [1:0] expected;
    integer pattern;
    half_adder dut (.a(a), .b(b), .sum(sum), .carry(carry));
    `include "checks.vh"
    initial begin
        init_checks;
        $dumpfile("sim/vcd/half_adder.vcd");
        $dumpvars(0, tb_half_adder);
        for (pattern = 0; pattern < 4; pattern = pattern + 1) begin
            {a, b} = pattern;
            expected = {1'b0, a} + {1'b0, b};
            #1;
            checks = checks + 1;
            $display("check %0d: %b + %b | expected {carry,sum}=%b actual=%b%b | %s",
                checks, a, b, expected, carry, sum,
                ({carry, sum} === expected) ? "PASS" : "FAIL");
            if ({carry, sum} !== expected)
                fail_check("truth-table output");
        end
        finish_checks;
    end
endmodule
