`timescale 1ns/1ps
// Fill every A[r][k] with a known byte, then read every column slice
// (group i, step k) and check all four lanes against the same pattern.
module tb_scratchpad_a;
    parameter DIM_W = 6;
    localparam MAX_DIM = 1 << DIM_W;
    localparam WORDS = MAX_DIM / 4;

    reg clk, wr_en, rd_en;
    reg [DIM_W-1:0] wr_row, rd_k;
    reg [DIM_W-3:0] wr_word, rd_group;
    reg [31:0] wr_data, expected, next_expected, held;
    integer step, prev_group, prev_k;
    reg have_prev;
    wire [31:0] rd_data;
    integer row, word, group, k, lane;

    `include "checks.vh"

    scratchpad_a #(.DIM_W(DIM_W)) dut (
        .clk(clk),
        .wr_en(wr_en), .wr_row(wr_row), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(rd_en), .rd_group(rd_group), .rd_k(rd_k), .rd_data(rd_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Distinct, signed-range byte for each element.
    function [7:0] element;
        input integer r, c;
        element = r*37 + c*11 + 3;
    endfunction

    initial begin
        init_checks;
        $dumpfile("sim/vcd/scratchpad_a.vcd");
        $dumpvars(0, tb_scratchpad_a);
        wr_en = 0; rd_en = 0; wr_row = 0; wr_word = 0; wr_data = 0;
        rd_group = 0; rd_k = 0;

        // Fetch-side writes: one row group of four k values per cycle.
        for (row = 0; row < MAX_DIM; row = row + 1)
            for (word = 0; word < WORDS; word = word + 1) begin
                @(negedge clk);
                wr_en = 1; wr_row = row; wr_word = word;
                for (lane = 0; lane < 4; lane = lane + 1)
                    wr_data[8*lane +: 8] = element(row, 4*word + lane);
            end
        @(negedge clk);
        wr_en = 0;

        // Compute-side reads, streamed like the tile sequencer: a new address
        // every cycle, so each result is checked while the NEXT address is
        // already applied. This catches byte selects not aligned to RAM latency.
        // lane r must be A[4*group + r][k].
        rd_en = 1;
        have_prev = 0;
        for (step = 0; step <= WORDS*MAX_DIM; step = step + 1) begin
            @(posedge clk);
            #1;
            if (step < WORDS*MAX_DIM) begin
                group = step / MAX_DIM;
                k = step % MAX_DIM;
                rd_group = group; rd_k = k;
                for (lane = 0; lane < 4; lane = lane + 1)
                    next_expected[8*lane +: 8] = element(4*group + lane, k);
            end
            #1;
            if (have_prev) begin
                checks = checks + 1;
                $display("check %0d: group %0d k=%0d | expected lanes=%h actual=%h | %s",
                    checks, prev_group, prev_k, expected, rd_data,
                    (rd_data === expected) ? "PASS" : "FAIL");
                if (rd_data !== expected)
                    fail_check("streamed read differs from written data");
            end
            expected = next_expected;
            prev_group = group; prev_k = k;
            have_prev = 1;
        end

        // With rd_en low, the output must hold even if the address changes.
        held = rd_data;
        @(negedge clk);
        rd_en = 0; rd_group = 0; rd_k = 1;
        repeat (2) @(posedge clk);
        #1;
        checks = checks + 1;
        $display("check %0d: rd_en=0 hold | expected=%h actual=%h | %s",
            checks, held, rd_data, (rd_data === held) ? "PASS" : "FAIL");
        if (rd_data !== held)
            fail_check("read data changed while rd_en was low");

        $display("DIM_W=%0d MAX_DIM=%0d", DIM_W, MAX_DIM);
        finish_checks_strict;
    end
endmodule
