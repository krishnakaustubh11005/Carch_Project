`timescale 1ns/1ps
// Dual-port RAM: every cycle both ports are checked against a reference
// model with read-first behaviour (a read returns the word as it was BEFORE
// this edge's writes, from either port).
//
// Phases:
//   1 fill all words from both ports at once, read all back from both ports
//   2 every byte-enable pattern on each port
//   3 read-during-write on the same port (old data, then new)
//   4 en=0 blocks writes and holds rdata; en=1 we=0 is a pure read
//   5 cross-port: one port reads the word the other port writes
//   6 first and last address with partial writes
//   7 random traffic on a few addresses (many collisions)
//   8 a second instance with ADDR_W=2, DATA_W=16
// Same-edge writes to one address from both ports are undefined and never driven.
module tb_dual_port_ram;
    parameter ADDR_W = 10;
    localparam WORDS = 1 << ADDR_W;

    reg clk;
    reg en_a, en_b;
    reg [3:0] we_a, we_b;
    reg [ADDR_W-1:0] addr_a, addr_b;
    reg [31:0] wdata_a, wdata_b;
    wire [31:0] rdata_a, rdata_b;

    // Small instance: 4 words of 16 bits.
    reg s_en_a, s_en_b;
    reg [1:0] s_we_a, s_we_b;
    reg [1:0] s_addr_a, s_addr_b;
    reg [15:0] s_wdata_a, s_wdata_b;
    wire [15:0] s_rdata_a, s_rdata_b;

    `include "checks.vh"

    dual_port_ram #(.ADDR_W(ADDR_W), .DATA_W(32)) dut (
        .clk(clk),
        .en_a(en_a), .we_a(we_a), .addr_a(addr_a), .wdata_a(wdata_a), .rdata_a(rdata_a),
        .en_b(en_b), .we_b(we_b), .addr_b(addr_b), .wdata_b(wdata_b), .rdata_b(rdata_b)
    );

    dual_port_ram #(.ADDR_W(2), .DATA_W(16)) dut_small (
        .clk(clk),
        .en_a(s_en_a), .we_a(s_we_a), .addr_a(s_addr_a), .wdata_a(s_wdata_a), .rdata_a(s_rdata_a),
        .en_b(s_en_b), .we_b(s_we_b), .addr_b(s_addr_b), .wdata_b(s_wdata_b), .rdata_b(s_rdata_b)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    reg [31:0] model [0:WORDS-1];
    reg [31:0] exp_a, exp_b;
    reg [15:0] s_model [0:3];
    reg [15:0] s_exp_a, s_exp_b;
    integer k, i, seed, phase;

    function [31:0] pattern;
        input integer a, salt;
        pattern = (a * 32'h9E3779B1) ^ (salt * 32'h01000193) ^ 32'hA5A5_0000;
    endfunction

    task report;
        input [8*8-1:0] port;
        input en, valid;
        input [3:0] we;
        input integer addr;
        input [31:0] expected, actual;
        begin
            checks = checks + 1;
            $display("check %0d: phase %0d port %0s en=%b we=%b addr=%0d | expected=%h actual=%h | %s",
                checks, phase, port, en, we, addr, expected, actual,
                (actual === expected) ? "PASS" : "FAIL");
            if (actual !== expected)
                fail_check("read data differs from the read-first model");
        end
    endtask

    // One clock with both ports driven. Expected read data is taken from the
    // model before this edge's writes; a disabled port must hold its rdata.
    task cyc;
        input ea; input [3:0] wa; input integer aa; input [31:0] da;
        input eb; input [3:0] wb; input integer ab; input [31:0] db;
        begin
            @(negedge clk);
            en_a = ea; we_a = wa; addr_a = aa; wdata_a = da;
            en_b = eb; we_b = wb; addr_b = ab; wdata_b = db;
            if (ea) exp_a = model[aa];
            if (eb) exp_b = model[ab];
            for (k = 0; k < 4; k = k + 1) begin
                if (ea && wa[k]) model[aa][8*k +: 8] = da[8*k +: 8];
                if (eb && wb[k]) model[ab][8*k +: 8] = db[8*k +: 8];
            end
            @(posedge clk);
            #1;
            report("A", ea, 1'b1, wa, aa, exp_a, rdata_a);
            report("B", eb, 1'b1, wb, ab, exp_b, rdata_b);
        end
    endtask

    task idle;
        begin
            @(negedge clk);
            en_a = 0; en_b = 0; we_a = 0; we_b = 0;
        end
    endtask

    task s_cyc;
        input ea; input [1:0] wa; input integer aa; input [15:0] da;
        input eb; input [1:0] wb; input integer ab; input [15:0] db;
        begin
            @(negedge clk);
            s_en_a = ea; s_we_a = wa; s_addr_a = aa; s_wdata_a = da;
            s_en_b = eb; s_we_b = wb; s_addr_b = ab; s_wdata_b = db;
            if (ea) s_exp_a = s_model[aa];
            if (eb) s_exp_b = s_model[ab];
            for (k = 0; k < 2; k = k + 1) begin
                if (ea && wa[k]) s_model[aa][8*k +: 8] = da[8*k +: 8];
                if (eb && wb[k]) s_model[ab][8*k +: 8] = db[8*k +: 8];
            end
            @(posedge clk);
            #1;
            report("A16", ea, 1'b1, {2'b00, wa}, aa, {16'd0, s_exp_a}, {16'd0, s_rdata_a});
            report("B16", eb, 1'b1, {2'b00, wb}, ab, {16'd0, s_exp_b}, {16'd0, s_rdata_b});
        end
    endtask

    reg r_ea, r_eb;
    reg [3:0] r_wa, r_wb;
    integer r_aa, r_ab;

    initial begin
        init_checks;
        $dumpfile("sim/vcd/dual_port_ram.vcd");
        $dumpvars(0, tb_dual_port_ram);
        en_a = 0; en_b = 0; we_a = 0; we_b = 0; addr_a = 0; addr_b = 0; wdata_a = 0; wdata_b = 0;
        s_en_a = 0; s_en_b = 0; s_we_a = 0; s_we_b = 0; s_addr_a = 0; s_addr_b = 0;
        s_wdata_a = 0; s_wdata_b = 0;
        seed = 32'h5EED;

        // Phase 1: A fills even words while B fills odd words, then each port
        // reads every word (A ascending, B descending, so they differ).
        phase = 1;
        for (i = 0; i < WORDS; i = i + 2)
            cyc(1, 4'b1111, i, pattern(i, 1), 1, 4'b1111, i + 1, pattern(i + 1, 1));
        for (i = 0; i < WORDS; i = i + 1)
            cyc(1, 4'b0000, i, 32'd0, 1, 4'b0000, WORDS - 1 - i, 32'd0);

        // Phase 2: each byte-enable pattern on each port: full write, partial
        // write, read back on the other port.
        phase = 2;
        for (i = 0; i < 16; i = i + 1) begin
            cyc(1, 4'b1111, 100 + i, 32'h11223344, 0, 4'b0000, 0, 32'd0);
            cyc(1, i, 100 + i, 32'hAABBCCDD, 0, 4'b0000, 0, 32'd0);
            cyc(0, 4'b0000, 0, 32'd0, 1, 4'b0000, 100 + i, 32'd0);
            cyc(0, 4'b0000, 0, 32'd0, 1, 4'b1111, 200 + i, 32'h55667788);
            cyc(0, 4'b0000, 0, 32'd0, 1, i, 200 + i, 32'h99AABBCC);
            cyc(1, 4'b0000, 200 + i, 32'd0, 0, 4'b0000, 0, 32'd0);
        end

        // Phase 3: a write returns the old word on the same port, the next
        // read returns the new word. Back-to-back writes to one address too.
        phase = 3;
        cyc(1, 4'b1111, 300, 32'hDEADBEEF, 1, 4'b1111, 301, 32'hCAFEF00D);
        cyc(1, 4'b1111, 300, 32'h0BADF00D, 1, 4'b1111, 301, 32'h12345678);
        cyc(1, 4'b0000, 300, 32'd0,        1, 4'b0000, 301, 32'd0);

        // Phase 4: en=0 with we set must not write and must hold rdata,
        // even while the address and data change.
        phase = 4;
        cyc(1, 4'b0000, 310, 32'd0, 1, 4'b0000, 311, 32'd0);
        cyc(0, 4'b1111, 310, 32'hFFFFFFFF, 0, 4'b1111, 311, 32'hFFFFFFFF);
        cyc(0, 4'b1111, 312, 32'h0, 0, 4'b1111, 313, 32'h0);
        cyc(1, 4'b0000, 310, 32'd0, 1, 4'b0000, 311, 32'd0);
        cyc(1, 4'b0000, 312, 32'd0, 1, 4'b0000, 313, 32'd0);

        // Phase 5: cross-port read of the word being written. The model gives
        // the old word (simulation behaviour; the design must not rely on it).
        phase = 5;
        cyc(1, 4'b1111, 320, 32'h01020304, 1, 4'b0000, 320, 32'd0);
        cyc(1, 4'b0000, 321, 32'd0,        1, 4'b0000, 320, 32'd0);
        cyc(1, 4'b0000, 321, 32'd0,        1, 4'b0011, 321, 32'hA0B0C0D0);
        cyc(1, 4'b0000, 321, 32'd0,        1, 4'b0000, 321, 32'd0);
        // both ports write different words on one edge
        cyc(1, 4'b1111, 322, 32'h0A0A0A0A, 1, 4'b1111, 323, 32'h0B0B0B0B);
        cyc(1, 4'b0000, 323, 32'd0,        1, 4'b0000, 322, 32'd0);

        // Phase 6: first and last address, partial writes from both ports.
        phase = 6;
        cyc(1, 4'b1111, 0, 32'h00000000, 1, 4'b1111, WORDS - 1, 32'hFFFFFFFF);
        cyc(1, 4'b1000, 0, 32'h7F000000, 1, 4'b0001, WORDS - 1, 32'h00000080);
        cyc(1, 4'b0000, WORDS - 1, 32'd0, 1, 4'b0000, 0, 32'd0);
        cyc(1, 4'b0000, 0, 32'd0, 1, 4'b0000, WORDS - 1, 32'd0);

        // Phase 7: random traffic on 8 addresses so reads and writes collide.
        // Both ports never write the same word on one edge.
        phase = 7;
        for (i = 0; i < 2000; i = i + 1) begin
            r_ea = $random(seed);
            r_eb = $random(seed);
            r_wa = $random(seed);
            r_wb = $random(seed);
            r_aa = 400 + ($random(seed) & 7);
            r_ab = 400 + ($random(seed) & 7);
            if (r_ea && r_eb && r_aa == r_ab && r_wa != 0)
                r_wb = 4'b0000;
            cyc(r_ea, r_wa, r_aa, $random(seed), r_eb, r_wb, r_ab, $random(seed));
        end
        // Read the random words back to confirm the final contents.
        for (i = 0; i < 8; i = i + 1)
            cyc(1, 4'b0000, 400 + i, 32'd0, 1, 4'b0000, 407 - i, 32'd0);
        idle;

        // Phase 8: a 16-bit, 4-word instance (other parameters).
        phase = 8;
        for (i = 0; i < 4; i = i + 2)
            s_cyc(1, 2'b11, i, 16'h1000 + i, 1, 2'b11, i + 1, 16'h2000 + i);
        for (i = 0; i < 4; i = i + 1)
            s_cyc(1, 2'b00, i, 16'd0, 1, 2'b00, 3 - i, 16'd0);
        for (i = 0; i < 4; i = i + 1) begin
            s_cyc(1, i, 2, 16'hABCD, 0, 2'b00, 0, 16'd0);
            s_cyc(0, 2'b00, 0, 16'd0, 1, i, 3, 16'h5A5A);
            s_cyc(1, 2'b00, 3, 16'd0, 1, 2'b00, 2, 16'd0);
        end

        $display("ADDR_W=%0d WORDS=%0d", ADDR_W, WORDS);
        finish_checks_strict;
    end
endmodule
