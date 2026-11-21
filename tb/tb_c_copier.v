`timescale 1ns/1ps
// c_copier between a real c_store and a real dual_port_ram.
//
// Per case:
//   1. Every one of the 64 x 64 c_store words gets a distinct value that also
//      depends on the case, so padding (rows >= M, cols >= N) and stale data
//      from an earlier case are both recognisable if they reach the RAM.
//   2. The whole RAM is filled with POISON.
//   3. The copy runs; one ignored start (other m/n/address) is injected
//      while busy. A monitor checks every RAM write in order (address, data,
//      byte enables, only while busy) and every c_store read (inside M x N
//      and below rows_ready).
//   4. Checks: done arrives, write sequence, write count, read limits, busy
//      length (exactly M*N + 1 without stalls), done is a single pulse and
//      the copier is idle afterwards.
//   5. All 4096 RAM words: C inside [base, base + M*N), POISON elsewhere.
// Stall cases raise rows_ready by 4 every STALL_STEP cycles, like a
// sequencer that finishes one row group at a time.
// A rst in the middle of a copy is checked between cases.
module tb_c_copier;
    parameter DIM_W = 6;
    localparam MAX_DIM = 1 << DIM_W;
    localparam RAM_ADDR_W = 12;
    localparam RAM_WORDS = 1 << RAM_ADDR_W;
    localparam BANK_ADDR_W = 2*DIM_W - 2;
    localparam [31:0] POISON = 32'hEEEEEEEE;
    localparam STALL_STEP = 25;
    localparam CHECKS_PER_CASE = 7;

    reg clk, rst, start;
    reg [RAM_ADDR_W-1:0] c_word_addr;
    reg [DIM_W:0] m, n, rows_ready;

    wire rd_en;
    wire [DIM_W-1:0] rd_row, rd_col;
    wire [31:0] rd_data;
    wire ram_en;
    wire [3:0] ram_we;
    wire [RAM_ADDR_W-1:0] ram_addr;
    wire [31:0] ram_wdata;
    wire busy, done;

    `include "checks.vh"

    c_store #(.DIM_W(DIM_W)) u_c_store (
        .clk(clk),
        .wr_en(4'b0000), .wr_addr({4*BANK_ADDR_W{1'b0}}), .wr_data(128'd0),
        .rd_en(rd_en === 1'b1), .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data)
    );

    c_copier #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) dut (
        .clk(clk), .rst(rst), .start(start),
        .c_word_addr(c_word_addr), .m(m), .n(n), .rows_ready(rows_ready),
        .rd_en(rd_en), .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data),
        .ram_en(ram_en), .ram_we(ram_we), .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .busy(busy), .done(done)
    );

    dual_port_ram #(.ADDR_W(RAM_ADDR_W), .DATA_W(32)) u_ram (
        .clk(clk),
        .en_a(1'b0), .we_a(4'b0000), .addr_a({RAM_ADDR_W{1'b0}}), .wdata_a(32'd0), .rdata_a(),
        .en_b(ram_en === 1'b1), .we_b(ram_we), .addr_b(ram_addr), .wdata_b(ram_wdata), .rdata_b()
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Distinct per (case, row, col); bit 31 varies, so sign bits are exercised.
    function [31:0] element;
        input integer case_id, r, c;
        element = (r*32'h01000193) ^ (c*32'h000111F3) ^ (case_id*32'h9E3779B1) ^ 32'h00C0FFEE;
    endfunction

    // Current job, as seen by the monitors.
    integer cur_case, exp_m, exp_n, exp_base;
    reg active;
    integer wr_index, seq_bad, rd_bad, busy_cycles, done_pulses, after_done_activity;
    reg done_seen;

    // Monitors sample at posedge, before the DUT's nonblocking updates.
    always @(posedge clk) begin
        if (active) begin
            if (ram_en === 1'b1) begin
                if (wr_index >= exp_m*exp_n
                    || ram_addr !== exp_base + wr_index
                    || ram_wdata !== element(cur_case, wr_index / exp_n, wr_index % exp_n)
                    || ram_we !== 4'b1111 || busy !== 1'b1) begin
                    seq_bad = seq_bad + 1;
                    if (seq_bad <= 3)
                        $display("    write %0d: expected addr 0x%03h data %08h, got en=%b we=%b addr 0x%03h data %08h",
                            wr_index, exp_base + wr_index,
                            element(cur_case, wr_index / exp_n, wr_index % exp_n),
                            ram_en, ram_we, ram_addr, ram_wdata);
                end
                wr_index = wr_index + 1;
            end
            if (rd_en === 1'b1 && (rd_row >= exp_m || rd_col >= exp_n || rd_row >= rows_ready)) begin
                rd_bad = rd_bad + 1;
                if (rd_bad <= 3)
                    $display("    illegal read row %0d col %0d (M %0d, N %0d, rows_ready %0d)",
                        rd_row, rd_col, exp_m, exp_n, rows_ready);
            end
            if (busy === 1'b1)
                busy_cycles = busy_cycles + 1;
            if (done === 1'b1)
                done_pulses = done_pulses + 1;
            if (done_seen && done !== 1'b1 && (busy !== 1'b0 || rd_en !== 1'b0 || ram_en !== 1'b0))
                after_done_activity = after_done_activity + 1;
        end
    end

    integer bank, r, c, a, k;

    task fill_c_store;
        input integer case_id;
        begin
            for (r = 0; r < MAX_DIM; r = r + 1)
                for (c = 0; c < MAX_DIM; c = c + 1)
                    case (r % 4)
                        0: u_c_store.g_bank[0].u_ram.mem[(r/4)*MAX_DIM + c] = element(case_id, r, c);
                        1: u_c_store.g_bank[1].u_ram.mem[(r/4)*MAX_DIM + c] = element(case_id, r, c);
                        2: u_c_store.g_bank[2].u_ram.mem[(r/4)*MAX_DIM + c] = element(case_id, r, c);
                        3: u_c_store.g_bank[3].u_ram.mem[(r/4)*MAX_DIM + c] = element(case_id, r, c);
                    endcase
        end
    endtask

    task poison_ram;
        begin
            for (a = 0; a < RAM_WORDS; a = a + 1)
                u_ram.mem[a] = POISON;
        end
    endtask

    task check;
        input ok;
        input [639:0] message;
        begin
            checks = checks + 1;
            if (!ok)
                fail_check(message);
        end
    endtask

    // stall = 0: rows_ready = M throughout. stall = 1: starts at 0, +4 every
    // STALL_STEP cycles until it reaches M.
    task run_case;
        input integer case_id, mm, nn, base, stall;
        integer timeout, expected_cycles, scan_bad, inside, want;
        begin
            fill_c_store(case_id);
            poison_ram;
            cur_case = case_id; exp_m = mm; exp_n = nn; exp_base = base;
            wr_index = 0; seq_bad = 0; rd_bad = 0; busy_cycles = 0;
            done_pulses = 0; after_done_activity = 0; done_seen = 0;
            expected_cycles = mm*nn + 1;

            @(negedge clk);
            rows_ready = stall ? 0 : mm;
            m = mm; n = nn; c_word_addr = base; start = 1;
            active = 1;
            @(negedge clk);
            start = 0;
            // An ignored start with a different job, while busy.
            @(negedge clk);
            m = 1; n = 1; c_word_addr = 0; start = 1;
            @(negedge clk);
            start = 0; m = mm; n = nn; c_word_addr = base;

            timeout = 0;
            while (done !== 1'b1 && timeout < 4*expected_cycles + 64*STALL_STEP) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (stall && (timeout % STALL_STEP) == 0 && rows_ready < mm)
                    rows_ready = (rows_ready + 4 > mm) ? mm : rows_ready + 4;
            end
            done_seen = (done === 1'b1);
            repeat (6) @(negedge clk);
            active = 0;

            check(done_seen, "done never arrived");
            check(seq_bad == 0, "RAM write sequence differs");
            check(wr_index == mm*nn, "wrong number of RAM writes");
            check(rd_bad == 0, "c_store read outside M x N or above rows_ready");
            check(stall ? busy_cycles >= expected_cycles : busy_cycles == expected_cycles,
                  "busy length differs");
            check(done_pulses == 1, "done is not a single-cycle pulse");
            check(after_done_activity == 0, "activity after done");

            scan_bad = 0;
            for (a = 0; a < RAM_WORDS; a = a + 1) begin
                inside = (a >= base) && (a < base + mm*nn);
                want = inside ? element(case_id, (a - base) / nn, (a - base) % nn) : POISON;
                checks = checks + 1;
                if (u_ram.mem[a] !== want) begin
                    scan_bad = scan_bad + 1;
                    if (scan_bad <= 3)
                        $display("    RAM[0x%03h]: expected %08h, actual %08h", a, want, u_ram.mem[a]);
                    fail_check("RAM scan: wrong word");
                end
            end

            $display("case %0d: %0dx%0d at word 0x%03h%0s | busy expected %0d%0s, actual %0d | writes expected %0d, actual %0d | RAM scan errors %0d | %s",
                case_id, mm, nn, base[RAM_ADDR_W-1:0], stall ? " (rows_ready stalls)" : "",
                expected_cycles, stall ? "+" : "", busy_cycles, mm*nn, wr_index, scan_bad,
                (seq_bad || rd_bad || scan_bad || !done_seen || wr_index != mm*nn) ? "FAIL" : "PASS");
        end
    endtask

    // rst part-way through: the copier must stop at once and stay idle.
    task reset_mid_copy;
        integer writes_after, done_after;
        begin
            fill_c_store(99);
            poison_ram;
            @(negedge clk);
            rows_ready = 8; m = 8; n = 8; c_word_addr = 12'h300; start = 1;
            @(negedge clk);
            start = 0;
            repeat (10) @(negedge clk);
            rst = 1;
            @(negedge clk);
            rst = 0;
            writes_after = 0; done_after = 0;
            check(busy === 1'b0, "busy still high after rst");
            for (k = 0; k < 20; k = k + 1) begin
                @(posedge clk);
                if (ram_en !== 1'b0 || rd_en !== 1'b0) writes_after = writes_after + 1;
                if (done !== 1'b0) done_after = done_after + 1;
            end
            check(writes_after == 0, "RAM or c_store access after rst");
            check(done_after == 0, "done after an abandoned copy");
            $display("reset mid-copy: busy after rst %b, accesses after %0d, done pulses %0d | %s",
                busy, writes_after, done_after,
                (busy === 1'b0 && writes_after == 0 && done_after == 0) ? "PASS" : "FAIL");
        end
    endtask

    initial begin
        init_checks;
        $dumpfile("sim/vcd/c_copier.vcd");
        $dumpvars(0, tb_c_copier);
        rst = 1; start = 0; m = 1; n = 1; c_word_addr = 0; rows_ready = 0; active = 0;
        repeat (2) @(negedge clk);
        rst = 0;

        //        case  M   N   base    stall
        run_case(  0,  2,  3, 12'h040, 0);   // worked example
        run_case(  1,  1,  1, 12'h000, 0);   // smallest, at word 0
        run_case(  2,  4,  4, 12'h100, 0);   // exactly one tile
        run_case(  3,  5,  7, 12'h123, 0);   // padding in both directions
        reset_mid_copy;
        run_case(  4, 64, 64, 12'h000, 0);   // largest: fills the whole RAM
        run_case(  5, 64,  1, 12'h800, 0);   // one column
        run_case(  6,  1, 64, 12'hFC0, 0);   // one row, ends at the last RAM word
        run_case(  7,  3, 64, 12'h200, 0);
        run_case(  8, 63, 63, 12'h050, 0);
        run_case(  9,  7,  5, 12'h400, 1);   // rows_ready pauses
        run_case( 10, 17,  9, 12'h600, 1);
        finish_checks_strict;
    end
endmodule
