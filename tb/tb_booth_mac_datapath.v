`timescale 1ns/1ps
module tb_booth_mac_datapath;
    parameter DATA_W = 8;
    parameter ACC_W = DATA_W + DATA_W + 8;
    reg signed [DATA_W-1:0] a, b;
    reg [ACC_W-1:0] acc_s, acc_c, expected, resolved;
    wire [ACC_W-1:0] sum, carry;
    integer fd, fields;
    reg [8191:0] vector_file;

    `include "checks.vh"
    booth_mac_datapath #(.DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .a(a), .b(b), .acc_s(acc_s), .acc_c(acc_c), .sum(sum), .carry(carry)
    );

    initial begin
        init_checks;
        $dumpfile("sim/vcd/booth_mac_datapath.vcd");
        $dumpvars(1, tb_booth_mac_datapath);
        if (DATA_W < 2 || ACC_W < DATA_W + DATA_W) begin
            fail_check("invalid DATA_W or ACC_W");
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
            fields = $fscanf(fd, "%h %h %h %h %h\n", a, b, acc_s, acc_c, expected);
            if (fields == 5) begin
                #1;
                checks = checks + 1;
                // This resolution exists only in the testbench, not the MAC loop.
                resolved = sum + carry;
                if (resolved !== expected) begin
                    if (errors < 10)
                        $display("a=%0d b=%0d S=%h C=%h output=%h expected=%h",
                            a, b, acc_s, acc_c, resolved, expected);
                    fail_check("carry-save MAC differs from Python golden model");
                end
            end else if (fields != -1) begin
                fail_check("malformed vector record");
                finish_checks_strict;
            end
        end
        $fclose(fd);
        $display("DATA_W=%0d ACC_W=%0d", DATA_W, ACC_W);
        finish_checks_strict;
    end
endmodule
