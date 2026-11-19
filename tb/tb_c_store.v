`timescale 1ns/1ps
// Write every C[R][Col] through the four bank ports, four rows per clock,
// then read every element back through the CPU-side port and check it.
module tb_c_store;
    parameter DIM_W = 6;
    localparam MAX_DIM = 1 << DIM_W;
    localparam GROUPS = MAX_DIM / 4;
    localparam BANK_ADDR_W = 2*DIM_W - 2;

    reg clk, rd_en;
    reg [3:0] wr_en;
    reg [4*BANK_ADDR_W-1:0] wr_addr;
    reg [127:0] wr_data;
    reg [DIM_W-1:0] rd_row, rd_col;
    reg [31:0] expected, next_expected, held;
    integer step, prev_row, prev_col;
    reg have_prev;
    wire [31:0] rd_data;
    integer group, col, bank, row;

    `include "checks.vh"

    c_store #(.DIM_W(DIM_W)) dut (
        .clk(clk),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Distinct 32-bit word for each element, including the sign byte.
    function [31:0] element;
        input integer r, c;
        element = r*32'h01000193 + c*32'h00011F3 + 32'h80000017;
    endfunction

    initial begin
        init_checks;
        $dumpfile("sim/vcd/c_store.vcd");
        $dumpvars(0, tb_c_store);
        wr_en = 0; wr_addr = 0; wr_data = 0; rd_en = 0; rd_row = 0; rd_col = 0;

        // Sequencer-side writes: all four banks on the same clock, one row
        // group and one column at a time, at address {row group, column}.
        for (group = 0; group < GROUPS; group = group + 1)
            for (col = 0; col < MAX_DIM; col = col + 1) begin
                @(negedge clk);
                wr_en = 4'b1111;
                for (bank = 0; bank < 4; bank = bank + 1) begin
                    wr_addr[BANK_ADDR_W*bank +: BANK_ADDR_W] = group*MAX_DIM + col;
                    wr_data[32*bank +: 32] = element(4*group + bank, col);
                end
            end
        @(negedge clk);
        wr_en = 0;

        // CPU-side reads with a new address every clock, so each result is
        // checked while the next address is already applied. This catches a
        // bank select that is not aligned with the RAM latency.
        rd_en = 1;
        have_prev = 0;
        for (step = 0; step <= MAX_DIM*MAX_DIM; step = step + 1) begin
            @(posedge clk);
            #1;
            if (step < MAX_DIM*MAX_DIM) begin
                row = step / MAX_DIM;
                col = step % MAX_DIM;
                rd_row = row; rd_col = col;
                next_expected = element(row, col);
            end
            #1;
            if (have_prev) begin
                checks = checks + 1;
                $display("check %0d: C[%0d][%0d] bank %0d | expected=%h actual=%h | %s",
                    checks, prev_row, prev_col, prev_row % 4, expected, rd_data,
                    (rd_data === expected) ? "PASS" : "FAIL");
                if (rd_data !== expected)
                    fail_check("read word differs from written word");
            end
            expected = next_expected;
            prev_row = row; prev_col = col;
            have_prev = 1;
        end

        // With rd_en low, the output must hold even if the address changes.
        held = rd_data;
        @(negedge clk);
        rd_en = 0; rd_row = 1; rd_col = 2;
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
