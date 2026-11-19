// On-chip copy of the result matrix C, split into four banks by row mod 4.
//
// Write side (tile sequencer): four independent ports, one per bank, so up
// to four results can be stored on the same clock.
//   wr_addr bank slice = {R div 4, column}; wr_data bank slice = 32-bit word.
//   A tile result C[4gi+r][4gj+c] therefore goes to bank r at {gi, gj, c}.
// Read side (CPU or testbench): one word per clock, addressed by (row, col).
//   Read latency is one clock, like the underlying block RAM.
//
// Placement: C[R][Col] -> bank R mod 4, word {R div 4, Col}.
// Each word holds one 24-bit signed result sign-extended to 32 bits.
// DIM_W=6 gives MAX_DIM=64: 4 banks x 1024 words = 16 KB.
// Port A of each RAM is the CPU side and port B the accelerator side,
// following the dual_port_ram convention.
module c_store #(
    parameter DIM_W = 6
) (
    input  wire clk,

    input  wire [3:0] wr_en,
    input  wire [4*(2*DIM_W-2)-1:0] wr_addr,
    input  wire [127:0] wr_data,

    input  wire rd_en,
    input  wire [DIM_W-1:0] rd_row,
    input  wire [DIM_W-1:0] rd_col,
    output wire [31:0] rd_data
);
    localparam BANK_ADDR_W = 2*DIM_W - 2;

    wire [BANK_ADDR_W-1:0] rd_addr = {rd_row[DIM_W-1:2], rd_col};
    wire [31:0] bank_word [0:3];

    // Bank of the word being read, aligned with the one-clock RAM latency.
    reg [1:0] rd_bank;
    always @(posedge clk)
        if (rd_en)
            rd_bank <= rd_row[1:0];

    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : g_bank
            dual_port_ram #(.ADDR_W(BANK_ADDR_W), .DATA_W(32)) u_ram (
                .clk(clk),
                .en_a(rd_en),
                .we_a(4'b0000),
                .addr_a(rd_addr),
                .wdata_a(32'd0),
                .rdata_a(bank_word[bank]),
                .en_b(wr_en[bank]),
                .we_b(4'b1111),
                .addr_b(wr_addr[BANK_ADDR_W*bank +: BANK_ADDR_W]),
                .wdata_b(wr_data[32*bank +: 32]),
                .rdata_b()
            );
        end
    endgenerate

    assign rd_data = bank_word[rd_bank];
endmodule
