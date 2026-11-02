module full_adder (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);
    wire intermediate_sum;
    wire carry_ab;
    wire carry_cin;

    half_adder add_operands (
        .a(a),
        .b(b),
        .sum(intermediate_sum),
        .carry(carry_ab)
    );

    half_adder add_carry_in (
        .a(intermediate_sum),
        .b(cin),
        .sum(sum),
        .carry(carry_cin)
    );

    assign cout = carry_ab | carry_cin;
endmodule
