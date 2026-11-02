`timescale 1ns/1ps
module tb_signed_multiplier;
    parameter DATA_W = 8;
    reg signed [DATA_W-1:0] a, b;
    wire signed [2*DATA_W-1:0] product;
    reg [2*DATA_W-1:0] expected_product;
    integer fd, fields;
    reg [8191:0] vector_file;
    signed_multiplier #(.DATA_W(DATA_W)) dut (.a(a), .b(b), .product(product));
    `include "checks.vh"
    initial begin
        init_checks;
        $dumpfile("sim/vcd/signed_multiplier.vcd");
        // Keep exhaustive-test waveforms bounded to testbench-level signals.
        $dumpvars(1, tb_signed_multiplier);
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
            fields = $fscanf(fd, "%h %h %h\n", a, b, expected_product);
            if (fields == 3) begin
                #1;
                checks = checks + 1;
                if (product !== expected_product) begin
                    if (errors < 10)
                        $display("a=%0d b=%0d actual=%h expected=%h", a, b, product, expected_product);
                    fail_check("golden-vector output");
                end
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks_strict;
            end
        end
        $fclose(fd);
        finish_checks_strict;
    end
endmodule
