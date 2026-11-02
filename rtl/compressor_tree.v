// Reduce aligned input rows to two vectors, modulo 2^WIDTH.
// Default structure: 7 -> 5 -> 4 -> 3 -> 2 rows, WIDTH columns per level.
// Each triple uses full adders; a remaining pair uses half adders.
module compressor_tree #(
    parameter WIDTH = 24,
    parameter ROWS = 7
) (
    input  wire [ROWS*WIDTH-1:0] rows,
    output wire [WIDTH-1:0] sum,
    output wire [WIDTH-1:0] carry
);
    generate
        if (ROWS == 1) begin : g_single_row
            assign sum = rows;
            assign carry = {WIDTH{1'b0}};
        end else if (ROWS == 2) begin : g_final_rows
            assign sum = rows[0 +: WIDTH];
            assign carry = rows[WIDTH +: WIDTH];
        end else begin : g_reduce
            localparam GROUP_COUNT = ROWS / 3;
            localparam TAIL_COUNT = ROWS % 3;
            localparam NEXT_ROWS = 2*GROUP_COUNT + TAIL_COUNT;

            wire [NEXT_ROWS*WIDTH-1:0] next_rows;
            genvar group_index, bit_index;

            // A full-adder bank turns three rows into a sum and shifted carry.
            for (group_index = 0; group_index < GROUP_COUNT; group_index = group_index + 1) begin : g_triples
                localparam INPUT_BASE = 3*group_index*WIDTH;
                localparam OUTPUT_BASE = 2*group_index*WIDTH;

                wire [WIDTH-1:0] row_a, row_b, row_c;
                wire [WIDTH-1:0] row_sum;
                wire [WIDTH:0] row_carry;

                assign row_a = rows[INPUT_BASE +: WIDTH];
                assign row_b = rows[INPUT_BASE + WIDTH +: WIDTH];
                assign row_c = rows[INPUT_BASE + 2*WIDTH +: WIDTH];
                assign row_carry[0] = 1'b0;

                for (bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1) begin : g_bits
                    full_adder u_full_adder (
                        .a(row_a[bit_index]),
                        .b(row_b[bit_index]),
                        .cin(row_c[bit_index]),
                        .sum(row_sum[bit_index]),
                        .cout(row_carry[bit_index + 1])
                    );
                end

                assign next_rows[OUTPUT_BASE +: WIDTH] = row_sum;
                // Discard row_carry[WIDTH]: arithmetic wraps at WIDTH bits.
                assign next_rows[OUTPUT_BASE + WIDTH +: WIDTH] = row_carry[WIDTH-1:0];
            end

            if (TAIL_COUNT == 1) begin : g_single_tail
                assign next_rows[2*GROUP_COUNT*WIDTH +: WIDTH] =
                    rows[(ROWS-1)*WIDTH +: WIDTH];
            end else if (TAIL_COUNT == 2) begin : g_pair_tail
                localparam INPUT_BASE = (ROWS-2)*WIDTH;
                localparam OUTPUT_BASE = 2*GROUP_COUNT*WIDTH;

                wire [WIDTH-1:0] row_a, row_b;
                wire [WIDTH-1:0] row_sum;
                wire [WIDTH:0] row_carry;

                assign row_a = rows[INPUT_BASE +: WIDTH];
                assign row_b = rows[INPUT_BASE + WIDTH +: WIDTH];
                assign row_carry[0] = 1'b0;

                for (bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1) begin : g_bits
                    half_adder u_half_adder (
                        .a(row_a[bit_index]),
                        .b(row_b[bit_index]),
                        .sum(row_sum[bit_index]),
                        .carry(row_carry[bit_index + 1])
                    );
                end

                assign next_rows[OUTPUT_BASE +: WIDTH] = row_sum;
                assign next_rows[OUTPUT_BASE + WIDTH +: WIDTH] = row_carry[WIDTH-1:0];
            end

            // Each elaborated level has fewer rows; stop at the two-row case.
            compressor_tree #(
                .WIDTH(WIDTH),
                .ROWS(NEXT_ROWS)
            ) u_next_level (
                .rows(next_rows),
                .sum(sum),
                .carry(carry)
            );
        end
    endgenerate
endmodule
