`timescale 1ns/1ps
module tb_compressor_tree;
    parameter WIDTH = 24;
    parameter ROWS = 7;
    reg [ROWS*WIDTH-1:0] rows;
    wire [WIDTH-1:0] sum, carry;
    reg [WIDTH-1:0] expected, resolved;
    integer fd, fields;
    reg [8191:0] vector_file;

    `include "checks.vh"
    compressor_tree #(.WIDTH(WIDTH), .ROWS(ROWS)) dut (
        .rows(rows), .sum(sum), .carry(carry)
    );

    initial begin
        init_checks;
        $dumpfile("sim/vcd/compressor_tree.vcd");
        $dumpvars(1, tb_compressor_tree);
        if (WIDTH < 1 || ROWS < 1) begin
            fail_check("WIDTH and ROWS must be positive");
            finish_checks_strict;
        end
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file)) begin
            fail_check("VECTOR_FILE is required");
            finish_checks_strict;
        end
        fd = $fopen(vector_file, "r");
        if (fd == 0) begin
            fail_check("cannot open vector file");
            finish_checks_strict;
        end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h\n", rows, expected);
            if (fields == 2) begin
                #1;
                checks = checks + 1;
                resolved = sum + carry;
                if (resolved !== expected) begin
                    if (errors < 10)
                        $display("rows=%h sum=%h carry=%h expected=%h", rows, sum, carry, expected);
                    fail_check("tree failed to preserve modular sum");
                end
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks_strict;
            end
        end
        $fclose(fd);
        $display("WIDTH=%0d ROWS=%0d", WIDTH, ROWS);
        finish_checks_strict;
    end
endmodule
