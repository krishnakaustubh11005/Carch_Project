// One unsigned, biased Booth row. The separate neg bit is added at its LSB.
// unsigned(pp) + neg = signed_digit_times_x + 2^(DATA_W+1).
// After shifting each row by 2j, the tree must subtract the sum of its biases.
module booth_pp_gen #(
    parameter DATA_W = 8
) (
    input  wire signed [DATA_W-1:0] x,
    input  wire sign,
    input  wire one,
    input  wire two,
    output wire [DATA_W+1:0] pp,
    output wire neg
);
    wire [DATA_W+1:0] x_extended;
    wire [DATA_W+1:0] x_twice;
    wire [DATA_W+1:0] selected;
    wire [DATA_W+1:0] complemented;

    // Two guard bits preserve the positive result of negating twice minimum x.
    assign x_extended = {{2{x[DATA_W-1]}}, x};
    assign x_twice = {x_extended[DATA_W:0], 1'b0};
    // one and two are mutually exclusive at the recoder output.
    assign selected = ({(DATA_W+2){one}} & x_extended) |
                      ({(DATA_W+2){two}} & x_twice);
    assign complemented = selected ^ {(DATA_W+2){sign}};

    // Replacing the negative sign weight by its inverted positive bit adds
    // the constant bias. There is no ACC_W-wide sign extension or adder here.
    assign pp = {~complemented[DATA_W+1], complemented[DATA_W:0]};
    assign neg = sign;
endmodule
