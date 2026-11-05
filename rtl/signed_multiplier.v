// Standalone product wrapper for verification of the Booth/tree datapath.
// This output resolution is outside the MAC carry-save feedback path.
module signed_multiplier #(
    parameter DATA_W = 8
) (
    input  wire signed [DATA_W-1:0] a,
    input  wire signed [DATA_W-1:0] b,
    output wire signed [DATA_W+DATA_W-1:0] product
);
    localparam PRODUCT_W = DATA_W + DATA_W;
    wire [PRODUCT_W-1:0] sum, carry;
    booth_mac_datapath #(.DATA_W(DATA_W), .ACC_W(PRODUCT_W)) datapath (
        .a(a), .b(b), .acc_s({PRODUCT_W{1'b0}}),
        .acc_c({PRODUCT_W{1'b0}}), .sum(sum), .carry(carry)
    );
    assign product = sum + carry;
    
endmodule
