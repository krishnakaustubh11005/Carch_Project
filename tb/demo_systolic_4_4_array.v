`timescale 1ns/1ps

// Small waveform example: A is 4x2, B is 2x4, and C is 4x4.
// Supply the two k positions on consecutive edges, then drain and flush.
// This is a directed demo, separate from the future full array test suite.
module demo_systolic_4_4_array;
    reg clk, rst, clear, en, drain_in;
    reg [31:0] a_in, b_in;
    reg [3:0] a_valid_in, b_valid_in;
    wire [383:0] results;
    wire [15:0] results_valid;
    reg [15:0] seen;
    integer errors, index, row_index, column_index, expected;

    systolic_4_4_array dut (
        .clk(clk), .rst(rst), .clear(clear), .en(en),
        .a_in(a_in), .b_in(b_in),
        .a_valid_in(a_valid_in), .b_valid_in(b_valid_in),
        .drain_in(drain_in), .results(results), .results_valid(results_valid)
    );

    // Named aliases make unpacked internal wire arrays easy to find in GTKWave.
    wire [7:0] a_skew0 = dut.a_skewed[0];
    wire [7:0] a_skew1 = dut.a_skewed[1];
    wire [7:0] a_skew2 = dut.a_skewed[2];
    wire [7:0] a_skew3 = dut.a_skewed[3];
    wire [7:0] b_skew0 = dut.b_skewed[0];
    wire [7:0] b_skew1 = dut.b_skewed[1];
    wire [7:0] b_skew2 = dut.b_skewed[2];
    wire [7:0] b_skew3 = dut.b_skewed[3];
    wire [3:0] drain_row0 = dut.drain_rows[0];
    wire [3:0] drain_row1 = dut.drain_rows[1];
    wire [3:0] drain_row2 = dut.drain_rows[2];
    wire [3:0] drain_row3 = dut.drain_rows[3];

    initial clk = 0;
    always #5 clk = ~clk;

    // Dump useful register/PE signals without expanding the structural adders.
    genvar row, column;
    generate
        for (row = 0; row < 4; row = row + 1) begin : g_watch_row
            for (column = 0; column < 4; column = column + 1) begin : g_watch_column
                wire signed [7:0] a_operand = dut.g_row[row].g_column[column].a_operand;
                wire signed [7:0] b_operand = dut.g_row[row].g_column[column].b_operand;
                wire a_valid = dut.g_row[row].g_column[column].a_operand_valid;
                wire b_valid = dut.g_row[row].g_column[column].b_operand_valid;
                wire [23:0] acc_s = dut.g_row[row].g_column[column].u_pe.acc_s;
                wire [23:0] acc_c = dut.g_row[row].g_column[column].u_pe.acc_c;
                wire signed [23:0] pe_result = results[24*(4*row+column) +: 24];
                wire pe_result_valid = results_valid[4*row+column];

                initial begin
                    #0;  // Let the main initial block select the VCD filename.
                    $dumpvars(0, a_operand, b_operand, a_valid, b_valid,
                              acc_s, acc_c, pe_result, pe_result_valid);
                end
            end
        end
    endgenerate

    // Check the 16 results as their publication wavefront arrives.
    always @(posedge clk) begin
        #1;
        if (!rst && !clear) begin
            for (index = 0; index < 16; index = index + 1) begin
                if (results_valid[index]) begin
                    row_index = index / 4;
                    column_index = index % 4;
                    expected = (row_index+1)*(10*(column_index+1)) +
                               (row_index+5)*(10*(column_index+1)+1);
                    if (seen[index] || $signed(results[24*index +: 24]) !== expected)
                        errors = errors + 1;
                    seen[index] = 1'b1;
                    $display("t=%0t PE(%0d,%0d): result=%0d expected=%0d",
                        $time, row_index, column_index,
                        $signed(results[24*index +: 24]), expected);
                end
            end
        end
    end

    initial begin
        $dumpfile("sim/vcd/array_demo.vcd");
        $dumpvars(1, demo_systolic_4_4_array);
        $dumpvars(1, dut);
        $dumpvars(1, dut.g_input_skew[1].g_delay);
        $dumpvars(1, dut.g_input_skew[2].g_delay);
        $dumpvars(1, dut.g_input_skew[3].g_delay);
        rst = 1; clear = 0; en = 1; drain_in = 0;
        a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0;
        seen = 0; errors = 0;
        repeat (2) @(negedge clk);
        rst = 0;

        // k=0: A lanes [0,1,2,3] = [1,2,3,4].
        //      B lanes [0,1,2,3] = [10,20,30,40].
        a_in = {8'd4, 8'd3, 8'd2, 8'd1};
        b_in = {8'd40, 8'd30, 8'd20, 8'd10};
        a_valid_in = 4'b1111; b_valid_in = 4'b1111;
        @(negedge clk);

        // k=1 immediately follows k=0, with no gap.
        a_in = {8'd8, 8'd7, 8'd6, 8'd5};
        b_in = {8'd41, 8'd31, 8'd21, 8'd11};
        @(negedge clk);

        // No next tile: send an invalid boundary step to publish this tile.
        a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0;
        drain_in = 1;
        @(negedge clk);
        drain_in = 0;
        repeat (7) @(negedge clk);  // Keep en=1 while all rows finish.

        if (seen !== 16'hffff || errors != 0) begin
            $display("TEST FAILED: seen=%h errors=%0d", seen, errors);
            $fatal(1);
        end
        $display("TEST PASSED: two consecutive input steps, 16 results checked");
        $finish;
    end

    initial begin
        #1000;
        $display("TEST FAILED: waveform demo timed out");
        $fatal(1);
    end
endmodule
