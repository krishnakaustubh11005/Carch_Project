// On-chip copy of matrix B: one 32-bit word per (row k, column group).
//
// Write side (fetch unit): one 32-bit group per cycle holding
//   B[wr_k][4*wr_word + 0 .. 4*wr_word + 3], byte 0 in bits [7:0].
// Read side (tile sequencer): rd_data lane c (bits 8*c+7 : 8*c) =
//   B[rd_k][4*rd_group + c], which is the b_in packing of systolic_4_4_array.
//   Read latency is one clock, like the underlying block RAM.
//
// Placement: B[k][c] -> word {k, c div 4}, byte c mod 4. The four bytes a
// step needs already sit in one row, so no banking is required.
// DIM_W=6 gives MAX_DIM=64: 1024 words = 4 KB.
module scratchpad_b #(
    parameter DIM_W = 6
) (
    input  wire clk,

    input  wire wr_en,
    input  wire [DIM_W-1:0] wr_k,
    input  wire [DIM_W-3:0] wr_word,
    input  wire [31:0] wr_data,

    input  wire rd_en,
    input  wire [DIM_W-3:0] rd_group,
    input  wire [DIM_W-1:0] rd_k,
    output wire [31:0] rd_data
);
    localparam ADDR_W = DIM_W + DIM_W - 2;

    dual_port_ram #(.ADDR_W(ADDR_W), .DATA_W(32)) u_ram (
        .clk(clk),
        .en_a(wr_en),
        .we_a(4'b1111),
        .addr_a({wr_k, wr_word}),
        .wdata_a(wr_data),
        .rdata_a(),
        .en_b(rd_en),
        .we_b(4'b0000),
        .addr_b({rd_k, rd_group}),
        .wdata_b(32'd0),
        .rdata_b(rd_data)
    );
endmodule
