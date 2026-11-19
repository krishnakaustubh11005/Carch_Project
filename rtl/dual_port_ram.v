// True dual-port RAM in the pattern FPGA tools map to block RAM.
// Both ports share one clock. Each port can read or write any word.
//   - Word-addressed: a CPU byte address maps to addr = byte_addr >> 2.
//   - we[i] writes byte i (bits 8*i+7 : 8*i) only; other bytes keep their value.
//   - Read latency is one clock: rdata shows the word addressed on the
//     previous rising edge. A write returns the OLD word on the same edge.
//   - Writing one address from both ports on the same edge is undefined.
//   - Reading a word on one port while the other port writes it returns the
//     old word in simulation; FPGA block RAM may not, so do not rely on it.
//   - en=0 blocks the write and holds rdata.
module dual_port_ram #(
    parameter ADDR_W = 10,              // 2^10 words = 4 KB
    parameter DATA_W = 32
) (
    input  wire clk,

    // Port A (CPU side later)
    input  wire en_a,
    input  wire [DATA_W/8-1:0] we_a,
    input  wire [ADDR_W-1:0] addr_a,
    input  wire [DATA_W-1:0] wdata_a,
    output reg  [DATA_W-1:0] rdata_a,

    // Port B (accelerator side later)
    input  wire en_b,
    input  wire [DATA_W/8-1:0] we_b,
    input  wire [ADDR_W-1:0] addr_b,
    input  wire [DATA_W-1:0] wdata_b,
    output reg  [DATA_W-1:0] rdata_b
);
    reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];
    integer byte_a;
    integer byte_b;

    always @(posedge clk) begin
        if (en_a) begin
            for (byte_a = 0; byte_a < DATA_W/8; byte_a = byte_a + 1)
                if (we_a[byte_a])
                    mem[addr_a][8*byte_a +: 8] <= wdata_a[8*byte_a +: 8];
            rdata_a <= mem[addr_a];
        end
    end

    always @(posedge clk) begin
        if (en_b) begin
            for (byte_b = 0; byte_b < DATA_W/8; byte_b = byte_b + 1)
                if (we_b[byte_b])
                    mem[addr_b][8*byte_b +: 8] <= wdata_b[8*byte_b +: 8];
            rdata_b <= mem[addr_b];
        end
    end
endmodule
