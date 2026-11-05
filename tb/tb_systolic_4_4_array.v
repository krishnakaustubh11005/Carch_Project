`timescale 1ns/1ps

// Python-golden stream: A is 4xK, B is Kx4, and each output is 4x4.
// Each multiplication consumes its own K consecutive source steps.
// A counter of PE(0,0)'s accepted pairs generates drain after K products.
// The next edge publishes the old sum and may accept the next matrix's product.
// Invalid inputs after the last matrix allow its final drain and pipeline flush.
// Default run is uninterrupted; +CONTROL_TESTS also exercises interruptions.
// Per-PE publication counters identify overlapping matrix result wavefronts.
module tb_systolic_4_4_array;
    // Testbench sizing only. The hardware remains a fixed, unparameterized 4x4.
    parameter MATRIX_COUNT = 2;
    reg clk, rst, clear, en;
    wire drain_in;
    reg [31:0] a_in, b_in;
    reg [3:0] a_valid_in, b_valid_in;
    wire [383:0] results;
    wire [15:0] results_valid;

    // Up to 4*256 bytes per input matrix; only 4*K entries are loaded/used.
    reg signed [7:0] a_matrices [0:MATRIX_COUNT-1][0:1023];
    reg signed [7:0] b_matrices [0:MATRIX_COUNT-1][0:1023];
    integer inner_size [0:MATRIX_COUNT-1];
    integer publish_cycle [0:MATRIX_COUNT-1];
    // expected[PE][matrix]: each PE reads its next Python result directly.
    // Example: expected[5][2] belongs to PE(1,1), third multiplication.
    reg signed [23:0] expected [0:15][0:MATRIX_COUNT-1];
    wire signed [23:0] actual [0:15];
    integer received [0:15];

    // Stimulus and monitor use separate loop variables to avoid races.
    integer row, column, k, matrix_index;
    integer vector_fd, fields, load_index, load_matrix;
    reg [8191:0] vector_file;
    reg [7:0] loaded_a, loaded_b;
    reg signed [23:0] loaded_c;
    // Only one PE loop index and three counters are needed by the checker.
    integer index;
    integer cycle, checks, errors;
    integer pe00_count, pe00_matrix;
    integer scenario, scenario_count, stimulus_step, saved_checks;
    reg checking;
    reg control_tests;

    // Consume a source step only after any stall/bubble has completed.
    task pause_source;
        input integer clocks;
        begin
            en = 0;
            repeat (clocks) @(negedge clk);
            en = 1;
        end
    endtask

    task bubble_source;
        begin
            a_valid_in = 0; b_valid_in = 0;
            @(negedge clk);
            a_valid_in = 15; b_valid_in = 15;
        end
    endtask

    task start_epoch;
        input integer use_clear;
        integer n;
        begin
            checking = 0;
            // Assert while stalled too: reset/clear must override en.
            en = 0;
            if (use_clear) clear = 1;
            else rst = 1;
            @(negedge clk);
            if (results !== 384'b0 || results_valid !== 16'b0) begin
                $display("Checks: %0d, errors: %0d", checks, errors + 1);
                $fatal(1, "TEST FAILED: reset/clear did not zero outputs");
            end
            rst = 0; clear = 0; en = 1;
            a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0;
            cycle = 0;
            for (n = 0; n < 16; n = n + 1) received[n] = 0;
            checking = 1;
        end
    endtask

    systolic_4_4_array dut (
        .clk(clk), .rst(rst), .clear(clear), .en(en),
        .a_in(a_in), .b_in(b_in),
        .a_valid_in(a_valid_in), .b_valid_in(b_valid_in),
        .drain_in(drain_in), .results(results), .results_valid(results_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Count accepted pairs for the matrix currently accumulated by PE(0,0).
    // Guard the final index: after its last drain there is no next matrix.
    assign drain_in = (pe00_matrix < MATRIX_COUNT) ?
        (en && pe00_count == inner_size[pe00_matrix]) : 1'b0;

    always @(posedge clk) begin
        if (rst || clear) begin
            pe00_count <= 0;
            pe00_matrix <= 0;
        end else if (en) begin
            if (drain_in) begin
                pe00_matrix <= pe00_matrix + 1;
                if (a_valid_in[0] && b_valid_in[0])
                    pe00_count <= 1;  // First product of the next matrix.
                else
                    pe00_count <= 0;  // Final publication: no next product.
            end else if (a_valid_in[0] && b_valid_in[0])
                pe00_count <= pe00_count + 1;
        end
    end

    // One GTKWave scope per output element; avoid dumping the FA/HA hierarchy.
    genvar pe;
    generate
        for (pe = 0; pe < 16; pe = pe + 1) begin : g_result_view
            assign actual[pe] = results[24*pe +: 24];
            wire signed [23:0] value = actual[pe];
            wire valid = results_valid[pe];
            initial begin
                #0;  // The main block selects the dump filename first.
                $dumpvars(0, value, valid);
            end
        end
    endgenerate

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("sim/vcd/systolic_4_4_array.vcd");
        $dumpvars(1, tb_systolic_4_4_array);
        rst = 1; clear = 0; en = 1;
        a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0;
        cycle = 0; checks = 0; errors = 0; checking = 0;
        control_tests = $test$plusargs("CONTROL_TESTS");

        // Python file per case: K, then 4*K A/B byte pairs, then 16 C values.
        // Loading all sizes first lets the counter choose each matrix's K.
        if (!$value$plusargs("VECTOR_FILE=%s", vector_file))
            vector_file = "golden/vectors/systolic_4_4_array.txt";
        vector_fd = $fopen(vector_file, "r");
        if (vector_fd == 0) begin
            $display("TEST FAILED: cannot open Python vectors; run make golden-array");
            $fatal(1);
        end
        for (load_matrix = 0; load_matrix < MATRIX_COUNT; load_matrix = load_matrix + 1) begin
            fields = $fscanf(vector_fd, "%d", inner_size[load_matrix]);
            if (fields != 1 || ^inner_size[load_matrix] === 1'bx ||
                inner_size[load_matrix] < 1 || inner_size[load_matrix] > 256) begin
                $display("TEST FAILED: invalid or missing K for matrix %0d", load_matrix+1);
                $fatal(1);
            end
            for (load_index = 0; load_index < 4*inner_size[load_matrix]; load_index = load_index + 1) begin
                fields = $fscanf(vector_fd, "%h %h", loaded_a, loaded_b);
                if (fields != 2 || ^{loaded_a, loaded_b} === 1'bx) begin
                    $display("TEST FAILED: invalid or missing input bytes");
                    $fatal(1);
                end
                a_matrices[load_matrix][load_index] = loaded_a;
                b_matrices[load_matrix][load_index] = loaded_b;
            end
            for (load_index = 0; load_index < 16; load_index = load_index + 1) begin
                fields = $fscanf(vector_fd, "%h", loaded_c);
                if (fields != 1 || ^loaded_c === 1'bx) begin
                    $display("TEST FAILED: invalid or missing Python result");
                    $fatal(1);
                end
                expected[load_index][load_matrix] = loaded_c;
            end
        end
        for (load_index = 0; load_index < 16; load_index = load_index + 1)
            received[load_index] = 0;
        // Reject extra tokens beyond the requested complete matrix stream.
        fields = $fscanf(vector_fd, "%s", vector_file);
        $fclose(vector_fd);
        if (fields == 1) begin
            $display("TEST FAILED: extra data after %0d matrix cases", MATRIX_COUNT);
            $fatal(1);
        end

        // Six independent epochs: continuous, stalls, bubbles, combined,
        // recovery after clear, and recovery after reset.
        scenario_count = control_tests ? 6 : 1;
        repeat (2) @(negedge clk);
        for (scenario = 0; scenario < scenario_count; scenario = scenario + 1) begin
            start_epoch(0);
            if (scenario >= 4) begin
                // Poison the mesh with valid products, leaving work in flight.
                checking = 0;
                a_in = 32'h7f7f7f7f; b_in = 32'h80808080;
                a_valid_in = 15; b_valid_in = 15;
                repeat (3) @(negedge clk);
                start_epoch(scenario == 4);
            end
            saved_checks = checks;
            stimulus_step = 0;
            for (matrix_index = 0; matrix_index < MATRIX_COUNT; matrix_index = matrix_index + 1) begin
                for (k = 0; k < inner_size[matrix_index]; k = k + 1) begin
                    // Pauses also hit tile boundaries and in-flight publications.
                    if ((scenario == 1 || scenario == 3) && stimulus_step % 3 == 1)
                        pause_source(3);
                    if ((scenario == 2 || scenario == 3) && stimulus_step % 2 == 1)
                        bubble_source;
                    a_valid_in = 15; b_valid_in = 15;
                    for (row = 0; row < 4; row = row + 1)
                        a_in[8*row +: 8] = a_matrices[matrix_index][inner_size[matrix_index]*row+k];
                    for (column = 0; column < 4; column = column + 1)
                        b_in[8*column +: 8] = b_matrices[matrix_index][4*k+column];
                    // Independent expected publication in enabled-step time:
                    // last product next edge, publication one enabled edge later.
                    if (k == inner_size[matrix_index]-1)
                        publish_cycle[matrix_index] = cycle + 2;
                    @(negedge clk);
                    stimulus_step = stimulus_step + 1;
                end
            end
            a_valid_in = 0; b_valid_in = 0; a_in = 0; b_in = 0;
            // Publish at PE(0,0), then stall with the marker inside the mesh.
            @(negedge clk);
            if (scenario == 1 || scenario == 3) pause_source(3);
            // Includes quiet tail to detect duplicate/unexpected publications.
            repeat (10) @(negedge clk);
            for (row = 0; row < 16; row = row + 1) begin
                if (received[row] != MATRIX_COUNT) begin
                    $display("ERROR: scenario %0d PE %0d received %0d results", scenario, row, received[row]);
                    errors = errors + 1;
                end
            end
            if (checks - saved_checks != 16*MATRIX_COUNT)
                errors = errors + 1;
            $display("CONTROL scenario=%0d checks=%0d cumulative_errors=%0d",
                     scenario, checks-saved_checks, errors);
        end
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors != 0 || checks != scenario_count*16*MATRIX_COUNT) begin
            $display("TEST FAILED");
            $fatal(1);
        end
        $display("TEST PASSED");
        $finish;
    end

    // Check results as they arrive. Each PE has its own received counter:
    // received=0 selects matrix 1, received=1 selects matrix 2, and so on.
    // This is needed because several matrix wavefronts overlap in the array.
    always @(posedge clk) begin
        #1;  // Wait for the PE's nonblocking register updates.
        if (!rst && !clear && checking) begin
            if (en) cycle = cycle + 1;
            if (!en && results_valid !== 16'b0) begin
                $display("ERROR: publication while array stalled");
                errors = errors + 1;
            end
            if (^results_valid === 1'bx) begin
                $display("ERROR: unknown result-valid bits at cycle %0d", cycle);
                errors = errors + 1;
            end

            for (index = 0; index < 16; index = index + 1) begin
                if (results_valid[index]) begin
                    if (received[index] >= MATRIX_COUNT) begin
                        $display("ERROR: extra result from PE(%0d,%0d)", index/4, index%4);
                        errors = errors + 1;
                    end else begin
                        $display("%0t | cycle %0d | matmul %0d | PE(%0d,%0d) | result=%0d expected=%0d",
                            $time, cycle, received[index]+1, index/4, index%4,
                            actual[index], expected[index][received[index]]);

                        if (actual[index] !== expected[index][received[index]]) begin
                            $display("ERROR: result differs from Python golden value");
                            errors = errors + 1;
                        end
                        // Each output wave follows that case's cumulative K steps.
                        if (cycle != publish_cycle[received[index]] + index/4 + index%4) begin
                            $display("ERROR: result arrived on the wrong cycle");
                            errors = errors + 1;
                        end
                    end
                    received[index] = received[index] + 1;
                    checks = checks + 1;
                end
            end
        end
    end

    initial begin
        #(10*(12*256*MATRIX_COUNT+2000));
        $display("TEST FAILED: timeout");
        $fatal(1);
    end
endmodule
