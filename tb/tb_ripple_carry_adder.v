`timescale 1ns/1ps
module tb_ripple_carry_adder;
    parameter WIDTH = 8;
    reg [WIDTH-1:0] a, b;
    reg cin;
    wire [WIDTH-1:0] sum;
    wire cout;
    reg [WIDTH-1:0] expected_sum;
    reg expected_cout;
    integer fd, fields;
    reg [8191:0] vector_file;
    ripple_carry_adder #(.WIDTH(WIDTH)) dut (.a(a), .b(b), .cin(cin), .sum(sum), .cout(cout));
    `include "checks.vh"
    initial begin
        init_checks;
        $dumpfile("sim/vcd/ripple_carry_adder.vcd");
        $dumpvars(0, tb_ripple_carry_adder);
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file)) begin
            fail_check("VECTOR_FILE is required");
            finish_checks;
        end
        fd = $fopen(vector_file, "r");
        if (fd == 0) begin
            fail_check("cannot open vector file");
            finish_checks;
        end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h %h %h %h\n", a, b, cin, expected_sum, expected_cout);
            if (fields == 5) begin
                #1;
                checks = checks + 1;
                if (sum !== expected_sum || cout !== expected_cout)
                    fail_check("golden-vector output");
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks;
            end
        end
        $fclose(fd);
        finish_checks;
    end
endmodule
