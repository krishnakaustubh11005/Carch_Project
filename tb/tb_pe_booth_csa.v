`timescale 1ns/1ps
module tb_pe_booth_csa;
    parameter DATA_W = 8;
    parameter K_MAX = 256;
    parameter ACC_W = 2*DATA_W + $clog2(K_MAX);
    reg clk, rst, clear, drain, en, a_valid_in, b_valid_in;
    reg signed [DATA_W-1:0] a_in, b_in;
    wire signed [DATA_W-1:0] a_out, b_out;
    wire a_valid_out, b_valid_out;
    wire signed [ACC_W-1:0] result;
    wire result_valid;

    reg [ACC_W-1:0] expected_acc, observed_acc, expected_result;
    reg [DATA_W-1:0] expected_a, expected_b;
    reg expected_av, expected_bv, expected_result_valid;
    reg [ACC_W-1:0] previous_s, previous_c, previous_result;
    reg [DATA_W-1:0] previous_a, previous_b;
    reg previous_av, previous_bv, previous_result_valid;
    integer fd, fields, mac_count, drain_count;
    reg [8191:0] vector_file;

    `include "checks.vh"

    pe_booth_csa #(.DATA_W(DATA_W), .K_MAX(K_MAX), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst(rst), .en(en), .clear(clear), .drain(drain),
        .a_in(a_in), .b_in(b_in), .a_valid_in(a_valid_in), .b_valid_in(b_valid_in),
        .a_out(a_out), .b_out(b_out), .a_valid_out(a_valid_out), .b_valid_out(b_valid_out),
        .result(result), .result_valid(result_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        init_checks;
        mac_count = 0;
        drain_count = 0;
        rst = 0; clear = 0; drain = 0; en = 0;
        a_valid_in = 0; b_valid_in = 0; a_in = 0; b_in = 0;
        $dumpfile("sim/vcd/pe_booth_csa.vcd");
        $dumpvars(1, tb_pe_booth_csa);
        if (DATA_W < 2 || K_MAX < 1 || ACC_W < 2*DATA_W + $clog2(K_MAX)) begin
            fail_check("invalid PE parameters");
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
            @(negedge clk);
            fields = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                rst, clear, drain, en, a_valid_in, b_valid_in, a_in, b_in,
                expected_acc, expected_a, expected_b, expected_av, expected_bv,
                expected_result, expected_result_valid);
            if (fields == 15) begin
                #1;
                if (checks > 0 &&
                    {dut.acc_s, dut.acc_c, a_out, b_out, a_valid_out, b_valid_out, result, result_valid} !==
                    {previous_s, previous_c, previous_a, previous_b, previous_av, previous_bv,
                     previous_result, previous_result_valid})
                    fail_check("registered state changed before the rising edge");

                @(posedge clk);
                #1;
                checks = checks + 1;
                observed_acc = dut.acc_s + dut.acc_c;
                if ({observed_acc, a_out, b_out, a_valid_out, b_valid_out, result, result_valid} !==
                    {expected_acc, expected_a, expected_b, expected_av, expected_bv,
                     expected_result, expected_result_valid}) begin
                    if (errors < 10)
                        $display("cycle=%0d controls=%b%b%b%b valid=%b%b acc=%h/%h result=%h/%h result_valid=%b/%b",
                            checks, rst, clear, drain, en, a_valid_in, b_valid_in,
                            observed_acc, expected_acc, result, expected_result,
                            result_valid, expected_result_valid);
                    fail_check("PE differs from integer golden model");
                end

                // Check the actual S/C representation also holds when no MAC is accepted.
                if (checks > 1 && !rst && !clear &&
                    (drain || !en || !a_valid_in || !b_valid_in) &&
                    {dut.acc_s, dut.acc_c} !== {previous_s, previous_c})
                    fail_check("carry-save state changed without an accepted MAC");

                if (!rst && !clear && drain)
                    drain_count = drain_count + 1;
                if (!rst && !clear && !drain && en && a_valid_in && b_valid_in)
                    mac_count = mac_count + 1;

                previous_s = dut.acc_s; previous_c = dut.acc_c;
                previous_a = a_out; previous_b = b_out;
                previous_av = a_valid_out; previous_bv = b_valid_out;
                previous_result = result; previous_result_valid = result_valid;
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks_strict;
            end
        end
        $fclose(fd);
        $display("DATA_W=%0d ACC_W=%0d K_MAX=%0d accepted_MACs=%0d drain_edges=%0d",
            DATA_W, ACC_W, K_MAX, mac_count, drain_count);
        finish_checks_strict;
    end
endmodule
