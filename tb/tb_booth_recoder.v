`timescale 1ns/1ps
module tb_booth_recoder;
    reg [2:0] window;
    wire window_sign, window_one, window_two;
    reg [7:0] operand;
    wire [8:0] operand_with_zero;
    wire [3:0] signs, ones, twos;
    integer pattern, value, group_index;
    integer expected_digit, decoded_digit, reconstructed, expected_value;
    reg expected_sign, expected_one, expected_two;

    `include "checks.vh"

    booth_recoder window_dut (
        .y(window), .sign(window_sign), .one(window_one), .two(window_two)
    );

    // Appending y[-1]=0 gives four overlapping windows for signed INT8.
    assign operand_with_zero = {operand, 1'b0};
    genvar digit_index;
    generate
        for (digit_index = 0; digit_index < 4; digit_index = digit_index + 1) begin : digits
            booth_recoder dut (
                .y(operand_with_zero[2*digit_index +: 3]),
                .sign(signs[digit_index]),
                .one(ones[digit_index]),
                .two(twos[digit_index])
            );
        end
    endgenerate

    task set_expected_digit;
        input [2:0] bits;
        begin
            // Independent arithmetic oracle: z = -2*y2 + y1 + y0.
            expected_digit = bits[1];
            expected_digit = expected_digit + bits[0];
            if (bits[2])
                expected_digit = expected_digit - 2;
            expected_sign = expected_digit < 0;
            expected_one = (expected_digit == 1) || (expected_digit == -1);
            expected_two = (expected_digit == 2) || (expected_digit == -2);
        end
    endtask

    initial begin
        init_checks;
        window = 0;
        operand = 0;
        $dumpfile("sim/vcd/booth_recoder.vcd");
        $dumpvars(0, tb_booth_recoder);

        for (pattern = 0; pattern < 8; pattern = pattern + 1) begin
            window = pattern;
            set_expected_digit(window);
            #1;
            checks = checks + 1;
            if ({window_sign, window_one, window_two} !==
                {expected_sign, expected_one, expected_two}) begin
                $display("window=%b expected flags=%b%b%b actual=%b%b%b", window,
                    expected_sign, expected_one, expected_two,
                    window_sign, window_one, window_two);
                fail_check("single-window recoding");
            end
        end

        for (value = 0; value < 256; value = value + 1) begin
            operand = value;
            #1;
            reconstructed = 0;
            for (group_index = 0; group_index < 4; group_index = group_index + 1) begin
                set_expected_digit(operand_with_zero[2*group_index +: 3]);
                checks = checks + 1;
                if ({signs[group_index], ones[group_index], twos[group_index]} !==
                    {expected_sign, expected_one, expected_two})
                    fail_check("digit flags differ from signed arithmetic oracle");

                decoded_digit = 0;
                if (ones[group_index])
                    decoded_digit = 1;
                if (twos[group_index])
                    decoded_digit = 2;
                if (signs[group_index])
                    decoded_digit = -decoded_digit;
                reconstructed = reconstructed + (decoded_digit << (2*group_index));
            end
            expected_value = value < 128 ? value : value - 256;
            checks = checks + 1;
            if (reconstructed !== expected_value) begin
                $display("y=%b expected=%0d reconstructed=%0d", operand,
                    expected_value, reconstructed);
                fail_check("sum of Booth digits times powers of four");
            end
        end

        $display("Exhaustive coverage: 8 windows, 256 signed INT8 operands");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors != 0) begin
            $display("TEST FAILED");
            $fatal(1, "Booth recoder verification failed");
        end
        $display("TEST PASSED");
        $finish;
    end
endmodule
