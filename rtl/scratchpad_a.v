// On-chip copy of matrix A, split into four banks by row mod 4.
//
// Write side (fetch unit): one 32-bit group per cycle holding
//   A[wr_row][4*wr_word + 0 .. 4*wr_word + 3], byte 0 in bits [7:0].
// Read side (tile sequencer): one column slice per cycle,
//   rd_data lane r (bits 8*r+7 : 8*r) = A[4*rd_group + r][rd_k],
//   which is the a_in packing of systolic_4_4_array.
//   Read latency is one clock, like the underlying block RAM.
//
// Placement: A[r][k] -> bank r mod 4, word {r div 4, k div 4}, byte k mod 4.
// All four banks are read at the same word, so the four rows of a tile
// arrive together. DIM_W=6 gives MAX_DIM=64: 4 banks x 256 words = 4 KB.
module scratchpad_a #(
    parameter DIM_W = 6
) (
    input  wire clk,

    input  wire wr_en,
    input  wire [DIM_W-1:0] wr_row,
    input  wire [DIM_W-3:0] wr_word,
    input  wire [31:0] wr_data,

    input  wire rd_en,
    input  wire [DIM_W-3:0] rd_group,
    input  wire [DIM_W-1:0] rd_k,
    output wire [31:0] rd_data
);
    localparam BANK_ADDR_W = 2*(DIM_W-2);

    wire [BANK_ADDR_W-1:0] wr_addr = {wr_row[DIM_W-1:2], wr_word};
    wire [BANK_ADDR_W-1:0] rd_addr = {rd_group, rd_k[DIM_W-1:2]};
    wire [31:0] bank_word [0:3];

    // Byte position of k inside each bank word, aligned with RAM latency.
    reg [1:0] rd_byte;
    always @(posedge clk)
        if (rd_en)
            rd_byte <= rd_k[1:0];

    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : g_bank
            dual_port_ram #(.ADDR_W(BANK_ADDR_W), .DATA_W(32)) u_ram (
                .clk(clk),
                .en_a(wr_en && wr_row[1:0] == bank),
                .we_a(4'b1111),
                .addr_a(wr_addr),
                .wdata_a(wr_data),
                .rdata_a(),
                .en_b(rd_en),
                .we_b(4'b0000),
                .addr_b(rd_addr),
                .wdata_b(32'd0),
                .rdata_b(bank_word[bank])
            );
            assign rd_data[8*bank +: 8] = bank_word[bank][8*rd_byte +: 8];
        end
    endgenerate
endmodule
