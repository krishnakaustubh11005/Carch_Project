// Combinational Booth MAC datapath. The future PE supplies the S/C registers.
// The default ACC_W matches the established sizing for K_MAX=256.
module booth_mac_datapath #(
    parameter DATA_W = 8,
    parameter ACC_W = 2*DATA_W + 8
) (
    input  wire signed [DATA_W-1:0] a,
    input  wire signed [DATA_W-1:0] b,
    input  wire [ACC_W-1:0] acc_s,
    input  wire [ACC_W-1:0] acc_c,
    output wire [ACC_W-1:0] sum,
    output wire [ACC_W-1:0] carry
);
    localparam BOOTH_GROUPS = (DATA_W + 1) / 2;
    localparam PP_WIDTH = DATA_W + 2;
    localparam TREE_ROWS = BOOTH_GROUPS + 3;
    localparam CORRECTION_ROW = BOOTH_GROUPS;
    localparam ACC_S_ROW = BOOTH_GROUPS + 1;
    localparam ACC_C_ROW = BOOTH_GROUPS + 2;

    // Every expression here is constant and evaluated during elaboration.
    // DIGIT_WEIGHTS = 1 + 4 + ... + 4^(BOOTH_GROUPS-1).
    // Subtract the combined bias introduced by inverting each PP sign bit.
    localparam [ACC_W-1:0] ACC_ONE = {{(ACC_W-1){1'b0}}, 1'b1};
    localparam [ACC_W-1:0] DIGIT_WEIGHTS =
        ((ACC_ONE << (2*BOOTH_GROUPS)) - ACC_ONE) / 3;
    localparam [ACC_W-1:0] BIAS_CORRECTION =
        -(DIGIT_WEIGHTS << (DATA_W + 1));

    wire [2*BOOTH_GROUPS:0] booth_bits;
    wire [BOOTH_GROUPS-1:0] neg_bits;
    wire [ACC_W-1:0] neg_correction;
    wire [ACC_W-1:0] correction_row;
    wire [TREE_ROWS*ACC_W-1:0] tree_rows;

    // Append y[-1]=0. Odd operand widths also need one top sign-padding bit.
    assign booth_bits = {{(2*BOOTH_GROUPS-DATA_W){b[DATA_W-1]}}, b, 1'b0};

    genvar digit_index, column;
    generate
        for (digit_index = 0; digit_index < BOOTH_GROUPS; digit_index = digit_index + 1) begin : g_booth_rows
            localparam ROW_SHIFT = 2*digit_index;
            localparam ROW_BASE = digit_index*ACC_W;

            wire [2:0] window_bits;
            wire sign, one, two;
            wire [PP_WIDTH-1:0] partial_product;
            wire [ACC_W-1:0] padded_product;

            assign window_bits = booth_bits[ROW_SHIFT +: 3];

            booth_recoder u_recoder (
                .y(window_bits),
                .sign(sign),
                .one(one),
                .two(two)
            );

            booth_pp_gen #(
                .DATA_W(DATA_W)
            ) u_pp_gen (
                .x(a),
                .sign(sign),
                .one(one),
                .two(two),
                .pp(partial_product),
                .neg(neg_bits[digit_index])
            );

            // PP rows are unsigned biased values: zero-extend, then align.
            assign padded_product = {{(ACC_W-PP_WIDTH){1'b0}}, partial_product};
            assign tree_rows[ROW_BASE +: ACC_W] = padded_product << ROW_SHIFT;
        end

        // Each neg bit is the +1 correction at its own row's starting column.
        for (column = 0; column < ACC_W; column = column + 1) begin : g_neg_columns
            if ((column % 2 == 0) && (column / 2 < BOOTH_GROUPS)) begin : g_neg_bit
                assign neg_correction[column] = neg_bits[column / 2];
            end else begin : g_zero
                assign neg_correction[column] = 1'b0;
            end
        end
    endgenerate

    // Neg bits and fixed bias bits occupy disjoint columns; no adder is needed.
    assign correction_row = BIAS_CORRECTION | neg_correction;
    assign tree_rows[CORRECTION_ROW*ACC_W +: ACC_W] = correction_row;
    assign tree_rows[ACC_S_ROW*ACC_W +: ACC_W] = acc_s;
    assign tree_rows[ACC_C_ROW*ACC_W +: ACC_W] = acc_c;

    compressor_tree #(
        .WIDTH(ACC_W),
        .ROWS(TREE_ROWS)
    ) u_compressor_tree (
        .rows(tree_rows),
        .sum(sum),
        .carry(carry)
    );
endmodule
