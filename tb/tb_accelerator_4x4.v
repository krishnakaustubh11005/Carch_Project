`timescale 1ns/1ps
module tb_accelerator_4x4;
    parameter MATRIX_COUNT = 2;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, load_we, load_b, start;
    reg [3:0] load_addr, result_addr;
    reg signed [7:0] load_data;
    wire busy, done;
    wire signed [23:0] result_data;
    reg [7:0] a [0:15], b [0:15];
    reg signed [23:0] expected [0:15];
    integer fd, fields, size, test_index, i, clocks;
    integer checks = 0, errors = 0;
    reg [8191:0] vector_file;
    reg [8191:0] extra;

    accelerator_4x4 dut (
        .clk(clk), .rst(rst), .load_we(load_we), .load_b(load_b),
        .load_addr(load_addr), .load_data(load_data), .start(start),
        .busy(busy), .done(done), .result_addr(result_addr),
        .result_data(result_data)
    );

    task require;
        input condition;
        input [511:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("ERROR: %0s", message);
                errors = errors + 1;
            end
        end
    endtask

    task reset_device;
        begin
            rst = 1; start = 0; load_we = 0;
            @(negedge clk);
            require(busy === 0 && done === 0, "reset must clear status");
            if (busy !== 0 || done !== 0) begin
                $display("Checks: %0d, errors: %0d\nTEST FAILED", checks, errors);
                $fatal(1);
            end
            rst = 0;
        end
    endtask

    task load_inputs;
        integer n;
        begin
            load_we = 1;
            for (n = 0; n < 16; n = n + 1) begin
                load_addr = n; load_b = 0; load_data = a[n];
                @(negedge clk);
                load_b = 1; load_data = b[n];
                @(negedge clk);
            end
            load_we = 0;
        end
    endtask

    task launch;
        begin
            start = 1;
            @(negedge clk);
            require(busy === 1 && done === 0, "start must set busy and clear done");
            start = 0;
        end
    endtask

    task finish_and_check;
        integer n, elapsed;
        reg signed [23:0] held;
        begin
            elapsed = 0;
            // Attempts to overwrite every input while busy must be ignored.
            while (done !== 1'b1 && elapsed < 40) begin
                start = 1; load_we = 1; load_addr = elapsed % 16;
                load_b = elapsed % 2; load_data = 8'h55;
                @(negedge clk);
                elapsed = elapsed + 1;
                if (done !== 1'b1)
                    require(busy === 1, "busy must stay set until completion");
            end
            start = 0; load_we = 0;
            require(done === 1 && busy === 0, "operation must finish within 40 clocks");
            for (n = 0; n < 16; n = n + 1) begin
                result_addr = n;
                #1;
                if (result_data !== expected[n]) begin
                    $display("ERROR: case %0d element %0d got %0d expected %0d",
                             test_index, n, result_data, expected[n]);
                    errors = errors + 1;
                end
                checks = checks + 1;
            end
            held = result_data;
            repeat (3) @(negedge clk);
            require(done === 1 && busy === 0 && result_data === held,
                    "done and output must remain stable while idle");
        end
    endtask

    initial begin
        $dumpfile("sim/vcd/accelerator_4x4.vcd");
        $dumpvars(1, tb_accelerator_4x4);
        rst = 1; load_we = 0; load_b = 0; start = 0;
        load_addr = 0; result_addr = 0; load_data = 0;
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file)) begin
            $display("Checks: 0, errors: 1\nTEST FAILED: missing VECTOR_FILE");
            $fatal(1);
        end
        fd = $fopen(vector_file, "r");
        if (!fd) $fatal(1, "TEST FAILED: cannot open vectors");
        repeat (2) @(negedge clk);
        reset_device;
        for (test_index = 0; test_index < MATRIX_COUNT; test_index = test_index + 1) begin
            fields = $fscanf(fd, "%d", size);
            if (fields != 1 || size !== 4) $fatal(1, "TEST FAILED: wrapper requires K=4");
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
            // Simultaneous write/start must perform only the write.
            start = 1; load_we = 1; load_b = 0; load_addr = 0; load_data = a[0];
            @(negedge clk);
            require(busy === 0, "write must take priority over start");
            start = 0; load_we = 0;
            launch;
            finish_and_check;
            // Repeat with stored inputs: catches corruption by busy-time writes.
            launch;
            finish_and_check;
            // Abort in CLEAR, FEED, DRAIN, and COLLECT, then recover.
            for (clocks = 0; clocks < 4; clocks = clocks + 1) begin
                launch;
                case (clocks)
                    0: begin end
                    1: repeat (2) @(negedge clk);
                    2: repeat (5) @(negedge clk);
                    3: repeat (8) @(negedge clk);
                endcase
                reset_device;
                for (i = 0; i < 16; i = i + 1) begin
                    result_addr = i; #1;
                    require(result_data === 0, "reset must clear result storage");
                end
                // Return to falling-edge drive after asynchronous read checks.
                @(negedge clk);
                load_inputs;
                launch;
                finish_and_check;
            end
        end
        fields = $fscanf(fd, "%s", extra);
        $fclose(fd);
        require(fields != 1, "extra vector tokens");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors || checks != MATRIX_COUNT*6*16) begin
            $display("TEST FAILED");
            $fatal(1);
        end
        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #(10*(1000*MATRIX_COUNT+100));
        $display("Checks: %0d, errors: %0d\nTEST FAILED: timeout", checks, errors+1);
        $fatal(1);
    end
endmodule
