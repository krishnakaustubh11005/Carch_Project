`timescale 1ns/1ps
module tb_carry_save_adder;
    parameter WIDTH = 8;
    reg [WIDTH-1:0] a, b, c;
    wire [WIDTH-1:0] sum, carry;
    reg [WIDTH-1:0] expected_sum, expected_carry;
    integer fd, fields;
    reg [8191:0] vector_file;
    carry_save_adder #(.WIDTH(WIDTH)) dut (.a(a), .b(b), .c(c), .sum(sum), .carry(carry));
    `include "checks.vh"
    initial begin
        init_checks;
        $dumpfile("sim/vcd/carry_save_adder.vcd");
        $dumpvars(0, tb_carry_save_adder);
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
            fields = $fscanf(fd, "%h %h %h %h %h\n", a, b, c, expected_sum, expected_carry);
            if (fields == 5) begin
                #1;
                checks = checks + 1;
                if (sum !== expected_sum || carry !== expected_carry)
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
