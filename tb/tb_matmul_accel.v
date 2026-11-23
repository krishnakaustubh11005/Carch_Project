`timescale 1ns/1ps
// Whole-job test of matmul_accel with a real 64 KB dual_port_ram, driven only
// through the MMIO registers, the way the CPU will.
//
// Python (golden/model.py, write_accel_vectors) supplies every job: M, K, N,
// byte addresses (A and B with any alignment) and the expected C words.
// Per job:
//   1. RAM filled with POISON, A and B bytes placed at their addresses
//      (the CPU's side; port A of the RAM is checked in tb_dual_port_ram).
//   2. Registers written and read back, START; odd jobs wait for irq, even
//      jobs poll STATUS.DONE.
//   3. STATUS, irq, JOBS_DONE, cycle counters; DONE cleared by W1C.
//   4. Every RAM word: C where C belongs, A and B unchanged, POISON
//      everywhere else.
// Job JOB_WITH_TRAFFIC also gets register writes and a rejected START while
// it runs; neither may change it.
// Then register tests: ID/CAPS, every START error code and its priority,
// a job placed exactly at the end of RAM, START+ABORT, and ABORT in each
// phase with a full job started right after it.
module tb_matmul_accel;
    parameter DIM_W = 6;
    localparam MAX_DIM = 1 << DIM_W;
    localparam RAM_ADDR_W = 14;
    localparam RAM_WORDS = 1 << RAM_ADDR_W;
    localparam RAM_BYTES = 4 * RAM_WORDS;
    // 1x1x1 job in the last two RAM words: B at END_B, A at END_A, C at END_C.
    localparam END_B = RAM_BYTES - 6, END_A = RAM_BYTES - 5, END_C = RAM_BYTES - 4;
    localparam [31:0] POISON = 32'hEEEEEEEE;
    localparam MAX_WAIT = 200000;
    localparam JOB_WITH_TRAFFIC = 4;

    // Register offsets.
    localparam [7:0] ID = 8'h00, CAPS = 8'h04, CTRL = 8'h08, STATUS = 8'h0C,
                     ERR_CODE = 8'h10, JOBS_DONE = 8'h14, FETCH_CYCLES = 8'h18,
                     COMPUTE_CYCLES = 8'h1C, REG_M = 8'h20, REG_N = 8'h24, REG_K = 8'h28,
                     A_ADDR = 8'h2C, B_ADDR = 8'h30, C_ADDR = 8'h34, IRQ_EN = 8'h38;

    reg clk, rst;
    reg bus_valid, bus_write;
    reg [7:0] bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire bus_ready, irq;
    wire ram_en;
    wire [3:0] ram_we;
    wire [RAM_ADDR_W-1:0] ram_addr;
    wire [31:0] ram_wdata, ram_rdata;

    `include "checks.vh"

    matmul_accel #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) dut (
        .clk(clk), .rst(rst),
        .bus_valid(bus_valid), .bus_write(bus_write), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ready(bus_ready), .irq(irq),
        .ram_en(ram_en), .ram_we(ram_we), .ram_addr(ram_addr),
        .ram_wdata(ram_wdata), .ram_rdata(ram_rdata)
    );

    dual_port_ram #(.ADDR_W(RAM_ADDR_W), .DATA_W(32)) u_ram (
        .clk(clk),
        .en_a(1'b0), .we_a(4'b0000), .addr_a({RAM_ADDR_W{1'b0}}), .wdata_a(32'd0), .rdata_a(),
        .en_b(ram_en === 1'b1), .we_b(ram_we), .addr_b(ram_addr), .wdata_b(ram_wdata),
        .rdata_b(ram_rdata)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- bus
    task bus_wr;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            bus_valid = 1; bus_write = 1; bus_addr = addr; bus_wdata = data;
            @(negedge clk);
            bus_valid = 0; bus_write = 0;
        end
    endtask

    task bus_rd;
        input [7:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            bus_valid = 1; bus_write = 0; bus_addr = addr;
            #1 data = bus_rdata;
            @(negedge clk);
            bus_valid = 0;
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

    // ---------------------------------------------------------------- job data
    integer M, K, N, a_base, b_base, c_base, case_index;
    reg [7:0] a_mat [0:MAX_DIM*MAX_DIM-1];
    reg [7:0] b_mat [0:MAX_DIM*MAX_DIM-1];
    reg [31:0] c_exp [0:MAX_DIM*MAX_DIM-1];
    reg [31:0] image [0:RAM_WORDS-1];   // expected RAM after the job
    integer i, w, value, fields, vector_fd;
    reg [8*256-1:0] vector_file;
    reg [31:0] rdata, status, jobs_before;

    task put_byte;   // into the expected image
        input integer byte_addr;
        input [7:0] data;
        reg [31:0] word;
        begin
            word = image[byte_addr >> 2];
            word = (word & ~(32'hFF << (8*(byte_addr % 4)))) | ({24'd0, data} << (8*(byte_addr % 4)));
            image[byte_addr >> 2] = word;
        end
    endtask

    // RAM holds POISON, A and B; image additionally holds the expected C.
    task load_ram;
        begin
            for (w = 0; w < RAM_WORDS; w = w + 1)
                image[w] = POISON;
            for (i = 0; i < M*K; i = i + 1) put_byte(a_base + i, a_mat[i]);
            for (i = 0; i < K*N; i = i + 1) put_byte(b_base + i, b_mat[i]);
            for (w = 0; w < RAM_WORDS; w = w + 1)
                u_ram.mem[w] = image[w];
            for (i = 0; i < M*N; i = i + 1)
                image[(c_base >> 2) + i] = c_exp[i];
        end
    endtask

    task program_job;
        input integer mm, nn, kk, aa, bb, cc;
        begin
            bus_wr(REG_M, mm); bus_wr(REG_N, nn); bus_wr(REG_K, kk);
            bus_wr(A_ADDR, aa); bus_wr(B_ADDR, bb); bus_wr(C_ADDR, cc);
        end
    endtask

    // Waits for irq (use_irq) or polls STATUS.DONE; returns 1 if it finished.
    task wait_done;
        input use_irq;
        output finished;
        integer waited;
        begin
            waited = 0;
            finished = 0;
            if (use_irq) begin
                while (irq !== 1'b1 && waited < MAX_WAIT) begin
                    @(negedge clk);
                    waited = waited + 1;
                end
                finished = (irq === 1'b1);
            end else begin
                rdata = 0;
                while (rdata[2] !== 1'b1 && waited < MAX_WAIT) begin
                    bus_rd(STATUS, rdata);
                    waited = waited + 2;
                end
                finished = (rdata[2] === 1'b1);
            end
        end
    endtask

    integer c_bad, other_bad;
    task scan_ram;
        begin
            c_bad = 0; other_bad = 0;
            for (w = 0; w < RAM_WORDS; w = w + 1) begin
                checks = checks + 1;
                if (u_ram.mem[w] !== image[w]) begin
                    if (w >= (c_base >> 2) && w < (c_base >> 2) + M*N) begin
                        c_bad = c_bad + 1;
                        if (c_bad <= 3)
                            $display("    C[%0d][%0d] (word 0x%04h): expected %0d, actual %0d",
                                (w - (c_base >> 2)) / N, (w - (c_base >> 2)) % N, w,
                                $signed(image[w]), $signed(u_ram.mem[w]));
                    end else begin
                        other_bad = other_bad + 1;
                        if (other_bad <= 3)
                            $display("    RAM word 0x%04h outside C: expected %08h, actual %08h",
                                w, image[w], u_ram.mem[w]);
                    end
                    fail_check("RAM differs from the expected image");
                end
            end
        end
    endtask

    // One job from the vector file, run through the registers.
    task run_job;
        input use_irq;
        input with_traffic;
        reg finished;
        integer tiles, period, compute_expected, fetch_bound;
        reg [31:0] fetch_cycles, compute_cycles;
        begin
            load_ram;
            bus_wr(IRQ_EN, use_irq);
            program_job(M, N, K, a_base, b_base, c_base);
            // Staging readback.
            fields = 0;
            bus_rd(REG_M, rdata);  fields = fields + (rdata == M);
            bus_rd(REG_N, rdata);  fields = fields + (rdata == N);
            bus_rd(REG_K, rdata);  fields = fields + (rdata == K);
            bus_rd(A_ADDR, rdata); fields = fields + (rdata == a_base);
            bus_rd(B_ADDR, rdata); fields = fields + (rdata == b_base);
            bus_rd(C_ADDR, rdata); fields = fields + (rdata == c_base);
            bus_rd(IRQ_EN, rdata); fields = fields + (rdata == use_irq);
            check(fields == 7, "register readback differs from what was written");
            bus_rd(JOBS_DONE, jobs_before);

            bus_wr(CTRL, 32'h1);
            bus_rd(STATUS, status);
            check(status[3:0] === 4'b0001, "STATUS after START is not BUSY only");

            if (with_traffic) begin
                // New staging values and a START while busy: rejected (code 4),
                // and the running job must not change.
                program_job(1, 1, 1, 0, 0, 0);
                bus_wr(CTRL, 32'h1);
                bus_rd(STATUS, status);
                bus_rd(ERR_CODE, rdata);
                check(status[3] === 1'b1 && rdata == 4, "START while busy not rejected with code 4");
                bus_wr(STATUS, 32'h8);   // clear ERROR
            end

            wait_done(use_irq, finished);
            check(finished, "job did not finish");
            check(irq === use_irq, "irq differs from IRQ_EN at the end of the job");
            bus_rd(STATUS, status);
            check(status[3:0] === 4'b0100, "STATUS after the job is not DONE only");
            bus_rd(JOBS_DONE, rdata);
            check(rdata == jobs_before + 1, "JOBS_DONE did not increase by one");

            // COMPUTE: 1 start cycle + sequencer (1 clear + tiles*P + 1 end
            // marker + 8 flush) + 1 cycle to see done. COPY: 1 start cycle +
            // M*N + 1 copier busy + 1 cycle to see done.
            tiles = ((M + 3) / 4) * ((N + 3) / 4);
            period = (K < 4) ? 4 : K;
            compute_expected = (1 + tiles*period + 10 + 1) + (1 + M*N + 1 + 1);
            // Fetch: each word once, plus at most one pause per row end and
            // a few cycles of start and finish per matrix, plus the fetch
            // unit's two setup cycles per matrix.
            fetch_bound = (M*K + 6)/4 + (K*N + 6)/4 + M + K + 8 + 2*2;
            bus_rd(FETCH_CYCLES, fetch_cycles);
            bus_rd(COMPUTE_CYCLES, compute_cycles);
            check(compute_cycles == compute_expected, "COMPUTE_CYCLES differs from the expected count");
            check(fetch_cycles > 0 && fetch_cycles <= fetch_bound, "FETCH_CYCLES outside its bound");

            bus_wr(STATUS, 32'h4);   // W1C DONE
            bus_rd(STATUS, status);
            check(status[2] === 1'b0 && irq === 1'b0, "DONE/irq not cleared by writing 1 to STATUS bit 2");

            scan_ram;
            $display("case %0d: %0dx%0dx%0d A@0x%04h B@0x%04h C@0x%04h (%0s%0s) | fetch %0d cycles (bound %0d) | compute+copy expected %0d, actual %0d | C errors %0d, other RAM errors %0d | %0s",
                case_index, M, K, N, a_base, b_base, c_base, use_irq ? "irq" : "poll",
                with_traffic ? ", traffic" : "", fetch_cycles, fetch_bound,
                compute_expected, compute_cycles, c_bad, other_bad,
                (finished && c_bad == 0 && other_bad == 0 && compute_cycles == compute_expected) ? "PASS" : "FAIL");
            if (M*N <= 12) begin
                for (i = 0; i < M; i = i + 1) begin
                    $write("    C row %0d:", i);
                    for (w = 0; w < N; w = w + 1)
                        $write(" %0d", $signed(u_ram.mem[(c_base >> 2) + i*N + w]));
                    $write("\n");
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- register tests
    task expect_error;
        input integer mm, nn, kk, aa, bb, cc, code;
        input [8*40-1:0] label;
        reg [31:0] err, jobs;
        begin
            bus_rd(JOBS_DONE, jobs_before);
            program_job(mm, nn, kk, aa, bb, cc);
            bus_wr(CTRL, 32'h1);
            bus_rd(STATUS, status);
            bus_rd(ERR_CODE, err);
            repeat (5) @(negedge clk);
            bus_rd(JOBS_DONE, jobs);
            check(status[3] === 1'b1 && status[0] === 1'b0, "rejected START: ERROR not set or job started");
            check(err == code, "wrong ERR_CODE");
            check(jobs == jobs_before && irq === 1'b0, "rejected START changed JOBS_DONE or raised irq");
            bus_wr(STATUS, 32'h8);
            bus_rd(STATUS, rdata);
            check(rdata[3] === 1'b0, "ERROR not cleared by writing 1 to STATUS bit 3");
            $display("error %0s: expected ERR_CODE %0d, actual %0d, STATUS %b | %0s",
                label, code, err, status[3:0],
                (status[3] === 1'b1 && status[0] === 1'b0 && err == code) ? "PASS" : "FAIL");
        end
    endtask

    // ABORT a 13x16x9 job after `delay` cycles and START a staged 1x1x1 job
    // two cycles later (A = 5 at END_A, B = -3 at END_B, C at END_C). The
    // aborted blocks must already be reset, or the quick job hangs or
    // produces a wrong C. Only the quick job's C word is checked: the
    // aborted job may leave C partly written.
    task abort_after;
        input integer delay;
        input [8*8-1:0] phase;
        reg finished;
        reg [31:0] jobs_after, c_word;
        begin
            u_ram.mem[RAM_WORDS-2] = 32'h05FDEEEE;
            u_ram.mem[RAM_WORDS-1] = POISON;
            bus_wr(STATUS, 32'hC);
            bus_wr(IRQ_EN, 1);
            bus_rd(JOBS_DONE, jobs_before);
            program_job(13, 9, 16, 0, 16'h1000, 16'h2000);
            bus_wr(CTRL, 32'h1);
            program_job(1, 1, 1, END_A, END_B, END_C);   // staging only
            repeat (delay - 12) @(negedge clk);
            bus_wr(CTRL, 32'h2);
            bus_rd(STATUS, status);
            bus_wr(CTRL, 32'h1);
            wait_done(1, finished);
            c_word = u_ram.mem[RAM_WORDS-1];
            bus_rd(JOBS_DONE, jobs_after);
            check(status[0] === 1'b0 && status[2] === 1'b0, "BUSY or DONE set right after ABORT");
            check(finished && c_word == 32'hFFFFFFF1, "job started right after ABORT failed");
            check(jobs_after == jobs_before + 1, "JOBS_DONE counted the aborted job or missed the next");
            bus_wr(STATUS, 32'h4);
            $display("abort during %0s: STATUS right after %b | next job C expected -15, actual %0d | JOBS_DONE %0d -> %0d (expected +1) | %0s",
                phase, status[3:0], $signed(c_word), jobs_before, jobs_after,
                (status[0] === 1'b0 && status[2] === 1'b0 && finished && c_word == 32'hFFFFFFF1
                 && jobs_after == jobs_before + 1) ? "PASS" : "FAIL");
        end
    endtask

    task register_tests;
        reg finished;
        begin
            bus_rd(ID, rdata);
            check(rdata == 32'h4D4D3434, "ID differs");
            $display("ID: expected 4d4d3434, actual %08h", rdata);
            bus_rd(CAPS, rdata);
            check(rdata == 32'h00000440, "CAPS differs (MAX_DIM 64, array 4, queue 0)");
            $display("CAPS: expected 00000440, actual %08h", rdata);
            bus_wr(IRQ_EN, 1);

            //            M    N    K   A_ADDR  B_ADDR  C_ADDR  code
            expect_error( 0,   4,   4,  0,      16'h1000, 16'h2000, 1, "M = 0");
            expect_error(65,   4,   4,  0,      16'h1000, 16'h2000, 1, "M = 65");
            expect_error( 4, 100,   4,  0,      16'h1000, 16'h2000, 1, "N = 100");
            expect_error( 4,   4,   0,  0,      16'h1000, 16'h2000, 1, "K = 0");
            expect_error( 0,   4,   4,  0,      16'h1000, 16'h2002, 1, "M = 0 and C unaligned (priority)");
            expect_error( 4,   4,   4,  0,      16'h1000, 16'h2002, 2, "C_ADDR = 0x2002");
            expect_error( 2,   4,   1,  RAM_BYTES-1, 16'h1000, 16'h2000, 5, "A ends past RAM");
            expect_error(64,  64,  64,  0,      RAM_BYTES-256, 16'h0000, 5, "B ends past RAM");
            expect_error( 1,   2,   1,  0,      16'h1000, END_C, 5, "C ends past RAM");
            expect_error( 4,   4,   4,  0,      16'h1000, RAM_BYTES, 5, "C starts past RAM");

            // A 1x1x1 job with C in the last RAM word and A, B in the word
            // before it (A[0][0] = 5 at END_A, B[0][0] = -3 at END_B).
            for (w = 0; w < RAM_WORDS; w = w + 1) begin
                u_ram.mem[w] = POISON;
                image[w] = POISON;
            end
            u_ram.mem[RAM_WORDS-2] = 32'h05FDEEEE;
            image[RAM_WORDS-2] = 32'h05FDEEEE;
            bus_rd(JOBS_DONE, jobs_before);
            program_job(1, 1, 1, END_A, END_B, END_C);
            bus_wr(CTRL, 32'h1);
            wait_done(1, finished);
            image[RAM_WORDS-1] = 32'hFFFFFFF1;       // C = -15 at END_C
            M = 1; N = 1; c_base = END_C;
            check(finished, "job at the end of RAM did not finish");
            scan_ram;
            $display("end-of-RAM job: C expected -15, actual %0d, other RAM errors %0d | %0s",
                $signed(u_ram.mem[RAM_WORDS-1]), other_bad,
                (finished && c_bad == 0 && other_bad == 0) ? "PASS" : "FAIL");
            bus_wr(STATUS, 32'h4);

            // START and ABORT in one write: ABORT wins, nothing starts.
            bus_wr(CTRL, 32'h3);
            bus_rd(STATUS, status);
            check(status[0] === 1'b0 && status[3] === 1'b0, "START+ABORT started a job or set ERROR");
            $display("start+abort: STATUS %b (expected 0000) | %0s", status[3:0],
                status[3:0] === 4'b0000 ? "PASS" : "FAIL");
        end
    endtask

    // ---------------------------------------------------------------- main
    integer saved [0:5];
    initial begin
        init_checks;
        $dumpfile("sim/vcd/matmul_accel.vcd");
        $dumpvars(1, tb_matmul_accel);
        rst = 1; bus_valid = 0; bus_write = 0; bus_addr = 0; bus_wdata = 0;
        repeat (3) @(negedge clk);
        rst = 0;

        case_index = 0;
        vector_fd = 0;
        vector_file = 0;
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file))
            fail_check("missing +VECTOR_FILE; run through make test-matmul_accel");
        else
            vector_fd = $fopen(vector_file, "r");
        if (vector_file != 0 && vector_fd == 0)
            fail_check("cannot open the vector file");
        if (vector_fd == 0)
            finish_checks_strict;

        while ($fscanf(vector_fd, "%d %d %d %h %h %h\n", M, K, N, a_base, b_base, c_base) == 6) begin
            fields = 0;
            for (i = 0; i < M*K; i = i + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                a_mat[i] = value;
            end
            for (i = 0; i < K*N; i = i + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                b_mat[i] = value;
            end
            for (i = 0; i < M*N; i = i + 1) begin
                fields = fields + $fscanf(vector_fd, "%h\n", value);
                c_exp[i] = value;
            end
            if (fields != M*K + K*N + M*N) begin
                fail_check("truncated vector file");
                finish_checks_strict;
            end
            run_job(case_index % 2, case_index == JOB_WITH_TRAFFIC);
            case_index = case_index + 1;
        end
        $fclose(vector_fd);
        if (case_index == 0)
            fail_check("vector file contains no jobs");
        $display("Jobs: %0d", case_index);

        // register_tests reuses M, N and c_base; keep the last file job.
        saved[0] = M; saved[1] = K; saved[2] = N;
        saved[3] = a_base; saved[4] = b_base; saved[5] = c_base;
        register_tests;
        // After errors and aborts, the last job from the file (its matrices
        // are still loaded) must run cleanly again.
        if (case_index > 0) begin
            M = saved[0]; K = saved[1]; N = saved[2];
            a_base = saved[3]; b_base = saved[4]; c_base = saved[5];
            case_index = case_index - 1;
            // ABORT during fetch, compute and copy of a 13x16x9 job (fetch
            // about 110 cycles, compute about 205, copy about 120), each
            // followed at once by a full job: the aborted blocks must have
            // been reset, not left running.
            abort_after(60, "fetch");
            $display("job right after the abort:");
            run_job(1, 0);
            abort_after(250, "compute");
            $display("job right after the abort:");
            run_job(0, 0);
            abort_after(390, "copy");
            $display("job right after the abort:");
            run_job(1, 0);
        end
        finish_checks_strict;
    end
endmodule
