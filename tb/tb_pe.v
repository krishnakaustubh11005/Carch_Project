`timescale 1ns/1ps
module tb_pe;
    `include "checks.vh"
    parameter DATA_W = 8;
    parameter K_MAX = 256;
    parameter ACC_W = 2*DATA_W + ceil_log2(K_MAX);
    reg clk, rst, clear, en, a_valid_in, b_valid_in;
    reg signed [DATA_W-1:0] a_in, b_in;
    wire signed [DATA_W-1:0] a_out, b_out;
    wire a_valid_out, b_valid_out;
    wire signed [ACC_W-1:0] acc_out;
    reg [ACC_W-1:0] expected_acc, previous_acc;
    reg [DATA_W-1:0] expected_a, expected_b, previous_a, previous_b;
    reg expected_av, expected_bv, previous_av, previous_bv;
    integer fd, fields;
    reg [8191:0] vector_file;

    pe #(.DATA_W(DATA_W), .K_MAX(K_MAX), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst(rst), .clear(clear), .en(en),
        .a_in(a_in), .b_in(b_in), .a_valid_in(a_valid_in), .b_valid_in(b_valid_in),
        .a_out(a_out), .b_out(b_out), .a_valid_out(a_valid_out), .b_valid_out(b_valid_out),
        .acc_out(acc_out)
    );
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        init_checks;
        rst = 0; clear = 0; en = 0;
        a_valid_in = 0; b_valid_in = 0; a_in = 0; b_in = 0;
        $dumpfile("sim/vcd/pe.vcd");
        $dumpvars(0, tb_pe);
        if (DATA_W < 2 || K_MAX < 1 || ACC_W < 2*DATA_W + ceil_log2(K_MAX)) begin
            fail_check("invalid PE parameters");
            finish_checks;
        end
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
            @(negedge clk);
            fields = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h\n",
                rst, clear, en, a_valid_in, b_valid_in, a_in, b_in,
                expected_acc, expected_a, expected_b, expected_av, expected_bv);
            if (fields == 12) begin
                // Inputs, including reset/clear, must not alter state before the edge.
                #1;
                if (checks > 0 && ({acc_out, a_out, b_out, a_valid_out, b_valid_out} !==
                    {previous_acc, previous_a, previous_b, previous_av, previous_bv}))
                    fail_check("state changed between clock edges");
                @(posedge clk);
                #1;
                checks = checks + 1;
                if ({acc_out, a_out, b_out, a_valid_out, b_valid_out} !==
                    {expected_acc, expected_a, expected_b, expected_av, expected_bv})
                    fail_check("PE state differs from golden model");
                previous_acc = expected_acc; previous_a = expected_a; previous_b = expected_b;
                previous_av = expected_av; previous_bv = expected_bv;
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks;
            end
        end
        $fclose(fd);
        finish_checks;
    end
endmodule
