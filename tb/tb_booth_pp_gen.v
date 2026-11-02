`timescale 1ns/1ps
module tb_booth_pp_gen;
    parameter DATA_W = 8;
    reg signed [DATA_W-1:0] x;
    reg sign, one, two;
    wire [DATA_W+1:0] pp;
    wire neg;
    reg [DATA_W+1:0] expected_pp;
    reg expected_neg;
    reg signed [DATA_W+2:0] expected_product;
    reg [DATA_W+2:0] bias, biased_sum, expected_biased_sum;
    integer fd, fields;
    reg [8191:0] vector_file;

    `include "checks.vh"

    booth_pp_gen #(.DATA_W(DATA_W)) dut (
        .x(x), .sign(sign), .one(one), .two(two), .pp(pp), .neg(neg)
    );

    task finish_pp_checks;
        begin
            if (checks == 0)
                fail_check("no test cases executed");
            $display("DATA_W=%0d; row width=%0d; bias=%0d", DATA_W, DATA_W+2, bias);
            $display("Checks: %0d, errors: %0d", checks, errors);
            if (errors != 0) begin
                $display("TEST FAILED");
                $fatal(1, "Booth partial-product verification failed");
            end
            $display("TEST PASSED");
            $finish;
        end
    endtask

    initial begin
        init_checks;
        bias = 0;
        bias[DATA_W+1] = 1'b1;
        $dumpfile("sim/vcd/booth_pp_gen.vcd");
        $dumpvars(0, tb_booth_pp_gen);
        if (DATA_W < 2) begin
            fail_check("DATA_W must be at least two");
            finish_pp_checks;
        end
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file)) begin
            fail_check("VECTOR_FILE is required");
            finish_pp_checks;
        end
        fd = $fopen(vector_file, "r");
        if (fd == 0) begin
            fail_check("cannot open vector file");
            finish_pp_checks;
        end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h %h %h %h %h\n",
                x, sign, one, two, expected_pp, expected_neg);
            if (fields == 6) begin
                #1;
                checks = checks + 1;
                // Independent identity check in addition to the Python row oracle.
                expected_product = {{3{x[DATA_W-1]}}, x};
                if (!one && !two)
                    expected_product = 0;
                else if (two)
                    expected_product = expected_product <<< 1;
                if (sign)
                    expected_product = -expected_product;
                expected_biased_sum = bias + expected_product;
                biased_sum = {1'b0, pp} + neg;
                if ((one && two) || pp !== expected_pp || neg !== expected_neg ||
                    biased_sum !== expected_biased_sum) begin
                    if (errors < 10)
                        $display("x=%0d controls=%b%b%b pp=%h neg=%b expected_pp=%h expected_neg=%b",
                            x, sign, one, two, pp, neg, expected_pp, expected_neg);
                    fail_check("biased row or separate correction bit");
                end
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_pp_checks;
            end
        end
        $fclose(fd);
        finish_pp_checks;
    end
endmodule
