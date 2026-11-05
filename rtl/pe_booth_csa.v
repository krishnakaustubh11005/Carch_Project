// Output-stationary, clocked Booth/carry-save processing element.
// Reset/clear override all work; drain publishes the old tile while en advances.
module pe_booth_csa #(
    parameter DATA_W = 8,
    parameter K_MAX = 256,
    parameter ACC_W = 2*DATA_W + $clog2(K_MAX)
) (
    input  wire clk,
    input  wire rst,
    input  wire en,
    input  wire clear,
    input  wire drain,
    input  wire signed [DATA_W-1:0] a_in,
    input  wire signed [DATA_W-1:0] b_in,
    input  wire a_valid_in,
    input  wire b_valid_in,
    output reg signed [DATA_W-1:0] a_out,
    output reg signed [DATA_W-1:0] b_out,
    output reg a_valid_out,
    output reg b_valid_out,
    output reg signed [ACC_W-1:0] result,
    output reg result_valid
);
    reg [ACC_W-1:0] acc_s;
    reg [ACC_W-1:0] acc_c;
    wire [ACC_W-1:0] next_s;
    wire [ACC_W-1:0] next_c;
    wire [ACC_W-1:0] mac_acc_s;
    wire [ACC_W-1:0] mac_acc_c;

    // A boundary MAC belongs to the next tile; exclude the previous tile's sum.
    assign mac_acc_s = drain ? {ACC_W{1'b0}} : acc_s;
    assign mac_acc_c = drain ? {ACC_W{1'b0}} : acc_c;

    booth_mac_datapath #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_mac (
        .a(a_in),
        .b(b_in),
        .acc_s(mac_acc_s),
        .acc_c(mac_acc_c),
        .sum(next_s),
        .carry(next_c)
    );

    always @(posedge clk) begin
        // Reset and clear have the same synchronous initialization action.
        if (rst || clear) begin
            acc_s <= {ACC_W{1'b0}};
            acc_c <= {ACC_W{1'b0}};
            a_out <= {DATA_W{1'b0}};
            b_out <= {DATA_W{1'b0}};
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
            result <= {ACC_W{1'b0}};
            result_valid <= 1'b0;
        end else begin
            // A drain indication lasts one clock, even if the array is stalled.
            result_valid <= 1'b0;

            if (drain) begin
                // Publication reads the old registers, independent of this MAC.
                result <= acc_s + acc_c;
                result_valid <= 1'b1;
            end

            if (en) begin
                // Forward each stream independently, including boundary cycles.
                a_out <= a_in;
                b_out <= b_in;
                a_valid_out <= a_valid_in;
                b_valid_out <= b_valid_in;
            end

            if (en && a_valid_in && b_valid_in) begin
                acc_s <= next_s;
                acc_c <= next_c;
            end else if (drain) begin
                // Without an accepted new pair, leave the next tile empty.
                acc_s <= {ACC_W{1'b0}};
                acc_c <= {ACC_W{1'b0}};
            end
        end
    end
endmodule
