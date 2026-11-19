`timescale 1ns/1ps
// Fetch unit: copy matrices of many shapes and alignments from a behavioural
// one-cycle-latency RAM, log every scratchpad write, and compare the log with
// the expected (row, word, data) sequence.
//
// Per case: one check per expected write, plus
//   done arrives, write count exact, RAM reads exact and in range,
//   cycle count within the 8-byte look-ahead model, busy low after done.
// One extra check: rst in the middle of a copy clears busy.
//
// The writes also drive a real scratchpad_a. For the cases marked `scan`,
// every bank word is first filled with POISON; after done, all 1,024 words
// (4 banks x 256) are read straight from the bank memories: words inside the
// matrix must hold the expected group, every other word must still be POISON.
// The same writes also drive a real scratchpad_b (the B copy: wr_row is k),
// which is scanned the same way: word {k, word}, 1,024 words.
module tb_fetch_unit;
    parameter DIM_W = 6;
    parameter RAM_ADDR_W = 12;              // 16 KB behavioural RAM
    localparam RAM_WORDS = 1 << RAM_ADDR_W;
    localparam NCASES = 16;
    localparam LOG_MAX = 1100;

    reg clk, rst, start;
    reg [RAM_ADDR_W+1:0] base_addr;
    reg [DIM_W:0] rows, cols;
    wire ram_en;
    wire [RAM_ADDR_W-1:0] ram_addr;
    reg [31:0] ram_rdata;
    wire wr_en;
    wire [DIM_W-1:0] wr_row;
    wire [DIM_W-3:0] wr_word;
    wire [31:0] wr_data;
    wire busy, done;

    `include "checks.vh"

    fetch_unit #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) dut (
        .clk(clk), .rst(rst), .start(start),
        .base_addr(base_addr), .rows(rows), .cols(cols),
        .ram_en(ram_en), .ram_addr(ram_addr), .ram_rdata(ram_rdata),
        .wr_en(wr_en), .wr_row(wr_row), .wr_word(wr_word), .wr_data(wr_data),
        .busy(busy), .done(done)
    );

    // Real scratchpad A on the fetch unit's write port (read port unused).
    localparam BANK_WORDS = 1 << (2*(DIM_W-2));
    localparam [31:0] POISON = 32'hEEEEEEEE;
    wire [31:0] sp_rd_data;
    scratchpad_a #(.DIM_W(DIM_W)) dut_sp (
        .clk(clk),
        .wr_en(wr_en === 1'b1), .wr_row(wr_row), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(1'b0), .rd_group({(DIM_W-2){1'b0}}), .rd_k({DIM_W{1'b0}}), .rd_data(sp_rd_data)
    );

    // Real scratchpad B on the same write port: B[k][...] with k = wr_row.
    localparam B_WORDS = 1 << (2*DIM_W-2);
    wire [31:0] spb_rd_data;
    scratchpad_b #(.DIM_W(DIM_W)) dut_spb (
        .clk(clk),
        .wr_en(wr_en === 1'b1), .wr_k(wr_row), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(1'b0), .rd_group({(DIM_W-2){1'b0}}), .rd_k({DIM_W{1'b0}}), .rd_data(spb_rd_data)
    );

    // Direct access to the bank memories (testbench only).
    task sp_poke;
        input integer bank, addr;
        input [31:0] value;
        case (bank)
            0: dut_sp.g_bank[0].u_ram.mem[addr] = value;
            1: dut_sp.g_bank[1].u_ram.mem[addr] = value;
            2: dut_sp.g_bank[2].u_ram.mem[addr] = value;
            default: dut_sp.g_bank[3].u_ram.mem[addr] = value;
        endcase
    endtask

    function [31:0] sp_peek;
        input integer bank, addr;
        case (bank)
            0: sp_peek = dut_sp.g_bank[0].u_ram.mem[addr];
            1: sp_peek = dut_sp.g_bank[1].u_ram.mem[addr];
            2: sp_peek = dut_sp.g_bank[2].u_ram.mem[addr];
            default: sp_peek = dut_sp.g_bank[3].u_ram.mem[addr];
        endcase
    endfunction

    initial clk = 0;
    always #5 clk = ~clk;

    // Distinct-looking byte for every RAM byte address.
    function [7:0] mem_byte;
        input integer a;
        mem_byte = a*37 + (a >> 8)*11 + 5;
    endfunction

    // Behavioural data RAM port: read data one cycle after ram_en.
    reg [31:0] mem [0:RAM_WORDS-1];
    always @(posedge clk)
        if (ram_en === 1'b1)
            ram_rdata <= mem[ram_addr];

    // Monitors: every RAM read and every scratchpad write.
    integer reads, bad_reads, nlog;
    integer exp_first, exp_last;
    reg [DIM_W-1:0] log_row [0:LOG_MAX-1];
    reg [DIM_W-3:0] log_word [0:LOG_MAX-1];
    reg [31:0] log_data [0:LOG_MAX-1];

    always @(posedge clk) begin
        if (ram_en === 1'b1) begin
            reads = reads + 1;
            if (ram_addr < exp_first || ram_addr > exp_last)
                bad_reads = bad_reads + 1;
        end
        if (wr_en === 1'b1) begin
            if (nlog < LOG_MAX) begin
                log_row[nlog] = wr_row;
                log_word[nlog] = wr_word;
                log_data[nlog] = wr_data;
            end
            nlog = nlog + 1;
        end
    end

    // Cases: base byte address, rows, cols, and the cycle count of the
    // 8-byte look-ahead model (start edge to the edge that raises done).
    integer case_base [0:NCASES-1];
    integer case_rows [0:NCASES-1];
    integer case_cols [0:NCASES-1];
    integer case_cycles [0:NCASES-1];
    reg case_scan [0:NCASES-1];

    task set_case;
        input integer n, b, r, c, cyc, scan;
        begin
            case_base[n] = b; case_rows[n] = r; case_cols[n] = c; case_cycles[n] = cyc;
            case_scan[n] = scan;
        end
    endtask

    integer n, i, w, lane, wpr, groups, words, cycles, timeout, col;
    integer bank, addr, sp_row, sp_word;
    reg [31:0] actual;
    reg [31:0] expected;
    reg [DIM_W-1:0] exp_row;
    reg [DIM_W-3:0] exp_word;
    reg ok;

    task run_case;
        input integer n;
        begin
            wpr = (case_cols[n] + 3) / 4;
            groups = case_rows[n] * wpr;
            exp_first = case_base[n] / 4;
            exp_last = (case_base[n] + case_rows[n]*case_cols[n] - 1) / 4;
            words = exp_last - exp_first + 1;
            timeout = 4*words + 4*groups + 64;
            reads = 0; bad_reads = 0; nlog = 0;
            if (case_scan[n]) begin
                for (bank = 0; bank < 4; bank = bank + 1)
                    for (addr = 0; addr < BANK_WORDS; addr = addr + 1)
                        sp_poke(bank, addr, POISON);
                for (addr = 0; addr < B_WORDS; addr = addr + 1)
                    dut_spb.u_ram.mem[addr] = POISON;
            end

            @(negedge clk);
            base_addr = case_base[n]; rows = case_rows[n]; cols = case_cols[n];
            start = 1;
            @(posedge clk);                  // start edge
            #1;
            @(negedge clk);
            start = 0;
            // cycles = clock edges after the start edge until done is high.
            cycles = 0;
            while (done !== 1'b1 && cycles < timeout) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            checks = checks + 1;
            $display("check %0d: case %0d base=0x%0h %0dx%0d done | expected=1 actual=%b | %s",
                checks, n, case_base[n], case_rows[n], case_cols[n], done,
                (done === 1'b1) ? "PASS" : "FAIL");
            if (done !== 1'b1)
                fail_check("done never pulsed");

            // Expected writes: row-major groups, unused lanes zero.
            for (i = 0; i < groups; i = i + 1) begin
                exp_row = i / wpr;
                exp_word = i % wpr;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    col = 4*(i % wpr) + lane;
                    expected[8*lane +: 8] = (col < case_cols[n])
                        ? mem_byte(case_base[n] + (i / wpr)*case_cols[n] + col) : 8'd0;
                end
                ok = (i < nlog) && (log_row[i] === exp_row) && (log_word[i] === exp_word)
                     && (log_data[i] === expected);
                checks = checks + 1;
                if (i < nlog)
                    $display("check %0d: case %0d write %0d | expected row=%0d word=%0d data=%h actual row=%0d word=%0d data=%h | %s",
                        checks, n, i, exp_row, exp_word, expected,
                        log_row[i], log_word[i], log_data[i], ok ? "PASS" : "FAIL");
                else
                    $display("check %0d: case %0d write %0d | expected row=%0d word=%0d data=%h actual=missing | FAIL",
                        checks, n, i, exp_row, exp_word, expected);
                if (!ok)
                    fail_check("scratchpad write differs");
            end

            checks = checks + 1;
            $display("check %0d: case %0d write count | expected=%0d actual=%0d | %s",
                checks, n, groups, nlog, (nlog == groups) ? "PASS" : "FAIL");
            if (nlog != groups)
                fail_check("wrong number of scratchpad writes");

            checks = checks + 1;
            $display("check %0d: case %0d RAM reads words 0x%0h-0x%0h | expected=%0d in range actual=%0d (%0d out of range) | %s",
                checks, n, exp_first, exp_last, words, reads, bad_reads,
                (reads == words && bad_reads == 0) ? "PASS" : "FAIL");
            if (reads != words || bad_reads != 0)
                fail_check("RAM reads not exactly the matrix words");

            checks = checks + 1;
            $display("check %0d: case %0d cycles | expected<=%0d actual=%0d | %s",
                checks, n, case_cycles[n], cycles,
                (done === 1'b1 && cycles <= case_cycles[n]) ? "PASS" : "FAIL");
            if (!(done === 1'b1 && cycles <= case_cycles[n]))
                fail_check("slower than the 8-byte look-ahead model");

            @(posedge clk);
            #1;
            checks = checks + 1;
            $display("check %0d: case %0d idle after done | expected busy=0 done=0 actual busy=%b done=%b | %s",
                checks, n, busy, done, (busy === 1'b0 && done === 1'b0) ? "PASS" : "FAIL");
            if (!(busy === 1'b0 && done === 1'b0))
                fail_check("busy or done still high after the copy");

            // Full scratchpad scan: bank b, word address {row div 4, word}.
            if (case_scan[n])
                for (bank = 0; bank < 4; bank = bank + 1)
                    for (addr = 0; addr < BANK_WORDS; addr = addr + 1) begin
                        sp_row = 4*(addr / (1 << (DIM_W-2))) + bank;
                        sp_word = addr % (1 << (DIM_W-2));
                        if (sp_row < case_rows[n] && sp_word < wpr)
                            for (lane = 0; lane < 4; lane = lane + 1) begin
                                col = 4*sp_word + lane;
                                expected[8*lane +: 8] = (col < case_cols[n])
                                    ? mem_byte(case_base[n] + sp_row*case_cols[n] + col) : 8'd0;
                            end
                        else
                            expected = POISON;
                        actual = sp_peek(bank, addr);
                        checks = checks + 1;
                        $display("check %0d: case %0d scratchpad bank %0d addr %0d (row %0d word %0d) | expected=%h actual=%h | %s",
                            checks, n, bank, addr, sp_row, sp_word, expected, actual,
                            (actual === expected) ? "PASS" : "FAIL");
                        if (actual !== expected)
                            fail_check("scratchpad word differs after the copy");
                    end

            // Full scratchpad_b scan: address {k, word}, k = row of the copied matrix.
            if (case_scan[n])
                for (addr = 0; addr < B_WORDS; addr = addr + 1) begin
                    sp_row = addr / (1 << (DIM_W-2));
                    sp_word = addr % (1 << (DIM_W-2));
                    if (sp_row < case_rows[n] && sp_word < wpr)
                        for (lane = 0; lane < 4; lane = lane + 1) begin
                            col = 4*sp_word + lane;
                            expected[8*lane +: 8] = (col < case_cols[n])
                                ? mem_byte(case_base[n] + sp_row*case_cols[n] + col) : 8'd0;
                        end
                    else
                        expected = POISON;
                    actual = dut_spb.u_ram.mem[addr];
                    checks = checks + 1;
                    $display("check %0d: case %0d scratchpad_b addr %0d (k %0d word %0d) | expected=%h actual=%h | %s",
                        checks, n, addr, sp_row, sp_word, expected, actual,
                        (actual === expected) ? "PASS" : "FAIL");
                    if (actual !== expected)
                        fail_check("scratchpad_b word differs after the copy");
                end
        end
    endtask

    initial begin
        init_checks;
        $dumpfile("sim/vcd/fetch_unit.vcd");
        $dumpvars(0, tb_fetch_unit);
        for (w = 0; w < RAM_WORDS; w = w + 1)
            mem[w] = {mem_byte(4*w+3), mem_byte(4*w+2), mem_byte(4*w+1), mem_byte(4*w)};

        //          n  base     rows cols cycles scan
        set_case( 0, 'h102,     3,   5,    9,  1);   // example from the discussion
        set_case( 1, 'h100,     4,   8,   10,  1);   // aligned
        set_case( 2, 'h101,     4,  16,   19,  1);   // unaligned, full speed
        set_case( 3, 'h103,     6,   5,   15,  1);   // offset 3, short row ends
        set_case( 4, 'h100,     8,   1,   10,  1);   // four rows per RAM word
        set_case( 5, 'h102,     4,   6,   11,  1);
        set_case( 6, 'h203,     1,   1,    3,  1);   // single byte
        set_case( 7, 'h001,     2,   3,    4,  1);
        set_case( 8, 'h400,    64,  64, 1026,  0);   // largest, aligned
        set_case( 9, 'h803,    64,  64, 1027,  1);   // largest, unaligned
        set_case(10, 'h1102,   64,   1,   66,  0);
        set_case(11, 'h2001,    5,  64,   83,  0);
        set_case(12, 'h2FFE,    7,  63,  115,  0);
        set_case(13, 'h3000,    1,  64,   18,  0);
        set_case(14, 'h3101,   64,   4,   67,  0);
        set_case(15, 'h3F00,   16,  16,   66,  0);   // ends at the last RAM byte

        rst = 1; start = 0; base_addr = 0; rows = 1; cols = 1;
        reads = 0; bad_reads = 0; nlog = 0; exp_first = 0; exp_last = RAM_WORDS - 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;

        for (n = 0; n < 4; n = n + 1)
            run_case(n);

        // rst in the middle of a large copy must stop it; the next case
        // then checks that a fresh start works normally.
        @(negedge clk);
        base_addr = 'h400; rows = 64; cols = 64; start = 1;
        @(negedge clk);
        start = 0;
        repeat (20) @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;
        #1;
        checks = checks + 1;
        $display("check %0d: rst during a copy | expected busy=0 actual busy=%b | %s",
            checks, busy, (busy === 1'b0) ? "PASS" : "FAIL");
        if (busy !== 1'b0)
            fail_check("rst did not stop the copy");

        for (n = 4; n < NCASES; n = n + 1)
            run_case(n);

        $display("DIM_W=%0d RAM_ADDR_W=%0d cases=%0d", DIM_W, RAM_ADDR_W, NCASES);
        finish_checks_strict;
    end
endmodule
