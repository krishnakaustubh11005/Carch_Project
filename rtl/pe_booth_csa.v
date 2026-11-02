// Output-stationary, clocked Booth/carry-save processing element.
// Priority: synchronous reset > clear > drain > enabled forwarding/MAC.
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

    booth_mac_datapath #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_mac (
        .a(a_in),
        .b(b_in),
        .acc_s(acc_s),
        .acc_c(acc_c),
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
                // Resolve only for publication; retain S/C and forwarding state.
                result <= acc_s + acc_c;
                result_valid <= 1'b1;
            end else if (en) begin
                // Forward the streams independently; consume a pair only if valid.
                a_out <= a_in;
                b_out <= b_in;
                a_valid_out <= a_valid_in;
                b_valid_out <= b_valid_in;

                if (a_valid_in && b_valid_in) begin
                    acc_s <= next_s;
                    acc_c <= next_c;
                end
            end
        end
    end
endmodule
