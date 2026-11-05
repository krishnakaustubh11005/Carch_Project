`timescale 1ns/1ps
module tb_accelerator_mmio;
    parameter MATRIX_COUNT = 2;
    // Non-default base verifies parameterized address decoding.
    localparam [31:0] BASE = 32'h20001000;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, mem_valid;
    reg [31:0] mem_addr, mem_wdata;
    reg [3:0] mem_wstrb;
    wire mem_ready;
    wire [31:0] mem_rdata;
    reg [7:0] a [0:15], b [0:15];
    reg signed [23:0] expected [0:15];
    reg [8191:0] vector_file, extra;
    reg [31:0] response;
    integer fd, fields, size, case_index, i, poll;
    integer checks = 0, errors = 0;

    accelerator_mmio #(.BASE_ADDR(BASE)) dut (
        .clk(clk), .rst(rst), .mem_valid(mem_valid), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata)
    );

    task require;
        input condition;
        input [511:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("ERROR case %0d: %0s", case_index, message);
                errors = errors + 1;
            end
        end
    endtask

    // Start/finish on falling edges. Keep request stable through its response.
    // Extra hold clocks test that one asserted request gets one response and
    // one side effect, even if valid remains high after acknowledgement.
    task transfer;
        input [31:0] address;
        input [31:0] data;
        input [3:0] strobes;
        input integer hold_clocks;
        integer wait_clocks, held;
        reg [31:0] latched;
        begin
            mem_valid = 1; mem_addr = address;
            mem_wdata = data; mem_wstrb = strobes;
            wait_clocks = 0;
            @(negedge clk);
            while (mem_ready !== 1'b1 && wait_clocks < 4) begin
                @(negedge clk);
                wait_clocks = wait_clocks + 1;
            end
            if (mem_ready !== 1'b1) begin
                $display("Checks: %0d, errors: %0d\nTEST FAILED: bus response timeout", checks, errors+1);
                $fatal(1);
            end
            latched = mem_rdata;
            response = latched;
            // Keep valid and payload stable through the rising-edge handshake.
            @(negedge clk);
            require(mem_ready === 0, "acknowledgement must last one clock");
            for (held = 0; held < hold_clocks; held = held + 1) begin
                // After response, even changed payload must not execute again.
                if (address != BASE) mem_wdata = ~data;
                @(negedge clk);
                require(mem_ready === 0, "duplicate response for held request");
                require(mem_rdata === latched, "response data changed without a new request");
            end
            mem_valid = 0; mem_wstrb = 0;
            @(negedge clk);
            require(mem_ready === 0, "ready must clear on request release");
        end
    endtask

    task read_status;
        begin
            transfer(BASE + 4, 0, 0, 0);
        end
    endtask

    task reset_device;
        begin
            rst = 1;
            @(negedge clk);
            require(mem_ready === 0 && mem_rdata === 0, "reset must clear bus response");
            rst = 0; mem_valid = 0; mem_wstrb = 0;
            @(negedge clk);
            read_status;
            require(response === 0, "reset must clear accelerator status");
        end
    endtask

    task load_inputs;
        integer n;
        begin
            for (n = 0; n < 16; n = n + 1) begin
                // Alternate byte and word writes; upper data bits are ignored.
                transfer(BASE + 32'h10 + 4*n, {24'habcdef, a[n]},
                         n % 2 ? 4'b0001 : 4'b1111, n == 0 ? 3 : 0);
                transfer(BASE + 32'h50 + 4*n, {24'h123456, b[n]},
                         n % 2 ? 4'b1111 : 4'b0001, 0);
            end
        end
    endtask

    task finish_and_check;
        integer n, attempts;
        reg [31:0] expected_word;
        begin
            response = 0;
            attempts = 0;
            while (response !== 32'h2 && attempts < 20) begin
                read_status;
                require(response === 1 || response === 2, "invalid active/completed status");
                attempts = attempts + 1;
            end
            require(response === 2, "operation did not complete");
            for (n = 0; n < 16; n = n + 1) begin
                transfer(BASE + 32'h90 + 4*n, 0, 0, n == 15 ? 3 : 0);
                expected_word = {{8{expected[n][23]}}, expected[n]};
                if (response !== expected_word) begin
                    $display("ERROR: case %0d C[%0d] got %h expected %h",
                             case_index, n, response, expected_word);
                    errors = errors + 1;
                end
                checks = checks + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/vcd/accelerator_mmio.vcd");
        $dumpvars(1, tb_accelerator_mmio);
        rst = 1; mem_valid = 0; mem_addr = 0; mem_wdata = 0; mem_wstrb = 0;
        case_index = 0;
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file))
            $fatal(1, "TEST FAILED: missing VECTOR_FILE");
        fd = $fopen(vector_file, "r");
        if (!fd) $fatal(1, "TEST FAILED: cannot open vectors");
        repeat (2) @(negedge clk);
        reset_device;
        for (case_index = 0; case_index < MATRIX_COUNT; case_index = case_index + 1) begin
            fields = $fscanf(fd, "%d", size);
            if (fields != 1 || size !== 4) $fatal(1, "TEST FAILED: MMIO requires K=4");
            for (i = 0; i < 16; i = i + 1) begin
                fields = $fscanf(fd, "%h %h", a[i], b[i]);
                if (fields != 2 || ^{a[i], b[i]} === 1'bx)
                    $fatal(1, "TEST FAILED: invalid input vector");
            end
            for (i = 0; i < 16; i = i + 1) begin
                fields = $fscanf(fd, "%h", expected[i]);
                if (fields != 1 || ^expected[i] === 1'bx)
                    $fatal(1, "TEST FAILED: invalid expected vector");
            end
            load_inputs;
            // Unsupported accesses are acknowledged but have no side effects.
            transfer(BASE + 32'h10, 32'h55aa0000, 4'b1110, 0);
            transfer(BASE + 32'h50, 32'h55aa0000, 4'b0010, 0);
            transfer(BASE + 32'h11, 32'h55, 4'b0001, 0);
            transfer(BASE + 32'hd0, 1, 4'b1111, 0);
            transfer(BASE + 32'h100, 1, 4'b1111, 0);
            transfer(BASE - 4, 1, 4'b1111, 0);
            transfer(BASE + 4, 1, 4'b1111, 0);
            transfer(BASE, 32'h100, 4'b0010, 0);
            transfer(BASE, 0, 4'b1111, 0);
            transfer(BASE + 1, 1, 4'b0001, 0);
            transfer(BASE + 32'hd0, 0, 0, 0);
            require(response === 0, "reserved reads must return zero");
            transfer(BASE + 32'h100, 0, 0, 0);
            require(response === 0, "out-of-window reads must return zero");
            transfer(BASE + 32'h11, 0, 0, 0);
            require(response === 0, "unaligned reads must return zero");
            transfer(BASE + 32'h10, 0, 0, 0);
            require(response === 0, "input registers are write-only");
            transfer(BASE, 0, 0, 0);
            require(response === 0, "control read must not start an operation");
            read_status;
            require(response === (case_index == 0 ? 32'h0 : 32'h2),
                    "unsupported accesses must preserve idle/completed status");
            // A long-held start must complete once, not retrigger after DONE.
            transfer(BASE, 1, 4'b1111, 24);
            finish_and_check;
            // Writes to results cannot alter them.
            transfer(BASE + 32'h90, 32'hdeadbeef, 4'b1111, 0);
            transfer(BASE + 32'h90, 0, 0, 0);
            require(response === {{8{expected[0][23]}}, expected[0]},
                    "writes to result registers must have no effect");
            transfer(BASE, 1, 4'b0001, 0);
            read_status;
            require(response === 1, "start must expose busy and clear old done");
            transfer(BASE + 32'h10, 8'h55, 4'b0001, 0);
            transfer(BASE + 32'h50, 8'h55, 4'b0001, 0);
            transfer(BASE, 1, 4'b0001, 0);
            finish_and_check;
            // Reuse inputs to detect deferred writes/restarts from busy requests.
            transfer(BASE, 1, 4'b0001, 0);
            finish_and_check;
            // Reset cancels an operation and a not-yet-accepted bus request.
            transfer(BASE, 1, 4'b0001, 0);
            mem_valid = 1; mem_addr = BASE; mem_wdata = 1; mem_wstrb = 15;
            reset_device;
            for (i = 0; i < 16; i = i + 1) begin
                transfer(BASE + 32'h90 + 4*i, 0, 0, 0);
                require(response === 0, "reset must clear result storage");
            end
            load_inputs;
            transfer(BASE, 1, 4'b0001, 0);
            finish_and_check;
        end
        fields = $fscanf(fd, "%s", extra);
        $fclose(fd);
        require(fields != 1, "extra vector tokens");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors || checks != MATRIX_COUNT*4*16) begin
            $display("TEST FAILED");
            $fatal(1);
        end
        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #(10*(1500*MATRIX_COUNT+100));
        $display("Checks: %0d, errors: %0d\nTEST FAILED: timeout", checks, errors+1);
        $fatal(1);
    end
endmodule
