`timescale 1ns/1ps
// End-to-end check of tile_sequencer with the real scratchpads and C store.
//
// Python (golden/model.py, write_tile_sequencer_vectors) supplies every
// M x K x N job and its expected C. This bench only:
//   1. pads A rows and B columns to multiples of 4 with zeros (the loader's
//      job, decision D-007) and writes both scratchpads,
//   2. starts the job, injects one ignored start while busy, and checks every
//      C write as it happens (value, position, written once, only while busy),
//   3. checks the job length, done/busy, the number of writes, and
//   4. reads all of C' back through the C store's CPU-side port.
// The second job is first aborted with rst part-way through, then rerun.
module tb_tile_sequencer;
    parameter DIM_W = 6;
    localparam MAX_DIM = 1 << DIM_W;
    localparam GROUP_W = DIM_W - 2;
    localparam C_ADDR_W = 2*DIM_W - 2;
    localparam MAX_CYCLES = 100000;
    localparam ABORT_CASE = 1;
    localparam ABORT_AFTER = 12;

    reg clk, rst, start;
    reg [GROUP_W-1:0] row_groups_m1, col_groups_m1;
    reg [DIM_W-1:0] k_m1;
    wire busy, done;

    reg a_wr_en, b_wr_en;
    reg [DIM_W-1:0] a_wr_row, b_wr_k;
    reg [GROUP_W-1:0] a_wr_word, b_wr_word;
    reg [31:0] a_wr_data, b_wr_data;
    wire a_rd_en, b_rd_en;
    wire [GROUP_W-1:0] a_rd_group, b_rd_group;
    wire [DIM_W-1:0] a_rd_k, b_rd_k;
    wire [31:0] a_rd_data, b_rd_data;
    wire [3:0] c_wr_en;
    wire [4*C_ADDR_W-1:0] c_wr_addr;
    wire [127:0] c_wr_data;
    reg c_rd_en;
    reg [DIM_W-1:0] c_rd_row, c_rd_col;
    wire [31:0] c_rd_data;

    `include "checks.vh"

    scratchpad_a #(.DIM_W(DIM_W)) u_scratchpad_a (
        .clk(clk),
        .wr_en(a_wr_en), .wr_row(a_wr_row), .wr_word(a_wr_word), .wr_data(a_wr_data),
        .rd_en(a_rd_en), .rd_group(a_rd_group), .rd_k(a_rd_k), .rd_data(a_rd_data)
    );

    scratchpad_b #(.DIM_W(DIM_W)) u_scratchpad_b (
        .clk(clk),
        .wr_en(b_wr_en), .wr_k(b_wr_k), .wr_word(b_wr_word), .wr_data(b_wr_data),
        .rd_en(b_rd_en), .rd_group(b_rd_group), .rd_k(b_rd_k), .rd_data(b_rd_data)
    );

    c_store #(.DIM_W(DIM_W)) u_c_store (
        .clk(clk),
        .wr_en(c_wr_en), .wr_addr(c_wr_addr), .wr_data(c_wr_data),
        .rd_en(c_rd_en), .rd_row(c_rd_row), .rd_col(c_rd_col), .rd_data(c_rd_data)
    );

    tile_sequencer #(.DIM_W(DIM_W)) dut (
        .clk(clk), .rst(rst),
        .start(start), .row_groups_m1(row_groups_m1), .col_groups_m1(col_groups_m1),
        .k_m1(k_m1), .busy(busy), .done(done),
        .a_rd_en(a_rd_en), .a_rd_group(a_rd_group), .a_rd_k(a_rd_k), .a_rd_data(a_rd_data),
        .b_rd_en(b_rd_en), .b_rd_group(b_rd_group), .b_rd_k(b_rd_k), .b_rd_data(b_rd_data),
        .c_wr_en(c_wr_en), .c_wr_addr(c_wr_addr), .c_wr_data(c_wr_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Current job, as read from the Python vector file.
    integer M, K, N, Mp, Np, tiles, period, case_index;
    reg [7:0] a_mat [0:MAX_DIM*MAX_DIM-1];
    reg [7:0] b_mat [0:MAX_DIM*MAX_DIM-1];
    reg [23:0] c_exp [0:MAX_DIM*MAX_DIM-1];
    reg written [0:MAX_DIM*MAX_DIM-1];
    integer write_count;
    reg job_active;

    integer vector_fd, fields, index, value, cycles;
    integer row, col, word, lane;
    reg [8191:0] vector_file;
    reg aborted;
    reg signed [23:0] readback [0:MAX_DIM*MAX_DIM-1];

    // Padded views: everything outside the real M x K x N job is zero.
    function [7:0] a_elem;
        input integer r, k;
        a_elem = (r < M && k < K) ? a_mat[r*K + k] : 8'd0;
    endfunction

    function [7:0] b_elem;
        input integer k, c;
        b_elem = (c < N) ? b_mat[k*N + c] : 8'd0;
    endfunction

    function [23:0] c_elem;
        input integer r, c;
        c_elem = (r < M && c < N) ? c_exp[r*N + c] : 24'd0;
    endfunction

    // Every C write is checked in mid-clock, before the RAM commits it.
    integer mon_bank, mon_row, mon_col;
    reg [C_ADDR_W-1:0] mon_addr;
    reg [31:0] mon_data;
    reg [23:0] mon_want;
    always @(negedge clk) begin
        for (mon_bank = 0; mon_bank < 4; mon_bank = mon_bank + 1) begin
            if (c_wr_en[mon_bank] === 1'b1) begin
                mon_addr = c_wr_addr[C_ADDR_W*mon_bank +: C_ADDR_W];
                mon_data = c_wr_data[32*mon_bank +: 32];
                mon_row = 4*(mon_addr >> DIM_W) + mon_bank;
                mon_col = mon_addr % MAX_DIM;
                checks = checks + 1;
                if (!job_active) begin
                    fail_check("C write while no job was running");
                end else if (mon_row >= Mp || mon_col >= Np) begin
                    fail_check("C write outside the padded M' x N' result");
                end else begin
                    mon_want = c_elem(mon_row, mon_col);
                    if (written[mon_row*MAX_DIM + mon_col] === 1'b1)
                        fail_check("C element written twice in one job");
                    if (mon_data !== {{8{mon_want[23]}}, mon_want}) begin
                        $display("  C[%0d][%0d] via bank %0d: expected %0d, wrote %0d",
                            mon_row, mon_col, mon_bank, $signed(mon_want), $signed(mon_data));
                        fail_check("C write differs from the Python golden value");
                    end
                    written[mon_row*MAX_DIM + mon_col] = 1'b1;
                    write_count = write_count + 1;
                end
            end
        end
    end

    // Loader: zero-padded A rows and B columns, four bytes per word.
    task load_scratchpads;
        begin
            for (row = 0; row < Mp; row = row + 1)
                for (word = 0; word < (K + 3) / 4; word = word + 1) begin
                    @(negedge clk);
                    a_wr_en = 1; a_wr_row = row; a_wr_word = word;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        a_wr_data[8*lane +: 8] = a_elem(row, 4*word + lane);
                end
            for (row = 0; row < K; row = row + 1)
                for (word = 0; word < Np / 4; word = word + 1) begin
                    @(negedge clk);
                    a_wr_en = 0;
                    b_wr_en = 1; b_wr_k = row; b_wr_word = word;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        b_wr_data[8*lane +: 8] = b_elem(row, 4*word + lane);
                end
            @(negedge clk);
            a_wr_en = 0; b_wr_en = 0;
        end
    endtask

    // Start one job; optionally abort it with rst after abort_after clocks.
    task run_job;
        input integer abort_after;
        begin
            for (index = 0; index < MAX_DIM*MAX_DIM; index = index + 1)
                written[index] = 1'b0;
            write_count = 0;
            aborted = 0;
            job_active = 1;
            @(negedge clk);
            row_groups_m1 = Mp/4 - 1; col_groups_m1 = Np/4 - 1; k_m1 = K - 1;
            start = 1;
            @(negedge clk);
            start = 0;
            cycles = 0;
            while (busy === 1'b1 && cycles < MAX_CYCLES && !aborted) begin
                cycles = cycles + 1;
                if (done !== 1'b0)
                    fail_check("done is high while busy");
                // A start while busy must be ignored, even with another size.
                if (cycles == 3) begin
                    start = 1; row_groups_m1 = 0; col_groups_m1 = 0; k_m1 = 0;
                end else begin
                    start = 0;
                end
                if (abort_after > 0 && cycles == abort_after) begin
                    rst = 1;
                    repeat (2) @(negedge clk);
                    rst = 0;
                    aborted = 1;
                    checks = checks + 1;
                    if (busy !== 1'b0 || done !== 1'b0)
                        fail_check("rst did not return the sequencer to idle");
                    $display("case %0d: aborted with rst after %0d busy clocks", case_index, cycles);
                end else begin
                    @(negedge clk);
                end
            end
            start = 0;
            job_active = 0;
        end
    endtask

    // Read the padded result back through the CPU-side port, one word per clock.
    task check_c;
        reg [31:0] want;
        reg [23:0] golden;
        begin
            c_rd_en = 1;
            for (row = 0; row < Mp; row = row + 1)
                for (col = 0; col < Np; col = col + 1) begin
                    @(negedge clk);
                    c_rd_row = row; c_rd_col = col;
                    @(posedge clk);
                    #1;
                    golden = c_elem(row, col);
                    want = {{8{golden[23]}}, golden};
                    checks = checks + 1;
                    readback[row*MAX_DIM + col] = c_rd_data[23:0];
                    if (c_rd_data !== want) begin
                        $display("  readback C[%0d][%0d]: expected %0d, got %0d",
                            row, col, $signed(want), $signed(c_rd_data));
                        fail_check("C store readback differs from Python golden");
                    end
                end
            @(negedge clk);
            c_rd_en = 0;
        end
    endtask

    initial begin
        init_checks;
        $dumpfile("sim/vcd/tile_sequencer.vcd");
        // Bench-level signals only: every sequencer port (busy, done, scratchpad
        // addresses, C writes) is visible here. Dumping every gate inside the
        // 16 PEs makes long jobs very slow, and naming the dut instance would
        // break the tooling check that compiles benches without hardware.
        $dumpvars(1, tb_tile_sequencer);
        rst = 1; start = 0; row_groups_m1 = 0; col_groups_m1 = 0; k_m1 = 0;
        a_wr_en = 0; a_wr_row = 0; a_wr_word = 0; a_wr_data = 0;
        b_wr_en = 0; b_wr_k = 0; b_wr_word = 0; b_wr_data = 0;
        c_rd_en = 0; c_rd_row = 0; c_rd_col = 0;
        job_active = 0; write_count = 0; M = 0; K = 0; N = 0; Mp = 0; Np = 0;
        repeat (3) @(negedge clk);
        rst = 0;

        case_index = 0;
        vector_fd = 0;
        vector_file = 0;
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file))
            fail_check("missing +VECTOR_FILE; run through make test-tile_sequencer");
        else
            vector_fd = $fopen(vector_file, "r");
        if (vector_file != 0 && vector_fd == 0)
            fail_check("cannot open the vector file");

        while (vector_fd != 0 && $fscanf(vector_fd, "%d %d %d\n", M, K, N) == 3) begin
            fields = 0;
            for (index = 0; index < M*K; index = index + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                a_mat[index] = value;
            end
            for (index = 0; index < K*N; index = index + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                b_mat[index] = value;
            end
            for (index = 0; index < M*N; index = index + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                c_exp[index] = value;
            end
            if (fields != M*K + K*N + M*N) begin
                fail_check("truncated vector file");
                finish_checks_strict;
            end

            Mp = ((M + 3) / 4) * 4;
            Np = ((N + 3) / 4) * 4;
            tiles = (Mp / 4) * (Np / 4);
            period = (K < 4) ? 4 : K;
            load_scratchpads;
            if (case_index == ABORT_CASE)
                run_job(ABORT_AFTER);
            run_job(0);

            // Busy clocks: 1 clear + tiles*P slots + 1 end marker + 8 flush.
            checks = checks + 1;
            if (cycles != tiles*period + 10) begin
                $display("  busy for %0d clocks, expected %0d", cycles, tiles*period + 10);
                fail_check("job length differs from 1 + tiles*P + 1 + 8 clocks");
            end
            checks = checks + 1;
            if (done !== 1'b1)
                fail_check("done is not high after the job");
            checks = checks + 1;
            if (write_count != Mp*Np) begin
                $display("  %0d C writes, expected %0d", write_count, Mp*Np);
                fail_check("number of C writes differs from M' x N'");
            end
            repeat (2) @(negedge clk);
            checks = checks + 1;
            if (done !== 1'b1 || busy !== 1'b0)
                fail_check("done must stay high and busy low until the next start");

            check_c;
            $display("case %0d: M=%0d K=%0d N=%0d -> %0d tiles, P=%0d, %0d busy clocks, %0d C writes",
                case_index, M, K, N, tiles, period, cycles, write_count);
            if (M*N <= 36) begin
                for (row = 0; row < M; row = row + 1) begin
                    $write("  C row %0d:", row);
                    for (col = 0; col < N; col = col + 1)
                        $write(" %6d", readback[row*MAX_DIM + col]);
                    $write("\n");
                end
            end
            case_index = case_index + 1;
        end

        if (vector_fd != 0)
            $fclose(vector_fd);
        if (vector_fd != 0 && case_index == 0)
            fail_check("vector file contains no jobs");
        $display("Jobs: %0d", case_index);
        finish_checks_strict;
    end
endmodule
