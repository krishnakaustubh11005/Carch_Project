// One radix-4 Booth digit from {y[2j+1], y[2j], y[2j-1]}.
module booth_recoder (
    input  wire [2:0] y,
    output wire sign,
    output wire one,
    output wire two
);
    assign one = y[1] ^ y[0];
    assign two = (~y[2] & y[1] & y[0]) |
                 (y[2] & ~y[1] & ~y[0]);
    assign sign = y[2] & ~(y[1] & y[0]); //This selects negation and Zero has sign 0.
endmodule
