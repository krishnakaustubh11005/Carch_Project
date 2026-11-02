`timescale 1ns/1ps
module tb_full_adder;
    reg a, b, cin;
    wire sum, cout;
    reg [1:0] expected;
    integer pattern;
    full_adder dut (.a(a), .b(b), .cin(cin), .sum(sum), .cout(cout));
    `include "checks.vh"
    initial begin
        init_checks;
        $dumpfile("sim/vcd/full_adder.vcd");
        $dumpvars(0, tb_full_adder);
        for (pattern = 0; pattern < 8; pattern = pattern + 1) begin
            {a, b, cin} = pattern;
            expected = {1'b0, a} + {1'b0, b} + {1'b0, cin};
            #1;
            checks = checks + 1;
            if ({cout, sum} !== expected)
                fail_check("truth-table output");
        end
        finish_checks;
    end
endmodule
