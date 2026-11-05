// Native-style, single-outstanding-request MMIO peripheral.
// One registered response per assertion of mem_valid; release valid to rearm.
// See ACCELERATOR_MMIO.md for register offsets and byte-lane semantics.
module accelerator_mmio #(
    parameter [31:0] BASE_ADDR = 32'h10000000
) (
    input wire clk,
    input wire rst,
    input wire mem_valid,
    input wire [31:0] mem_addr,
    input wire [31:0] mem_wdata,
    input wire [3:0] mem_wstrb,
    output reg mem_ready,
    output reg [31:0] mem_rdata
);
    reg served;
    wire accept = mem_valid && !served && !rst;
    wire [31:0] offset = mem_addr - BASE_ADDR;
    wire aligned = offset[1:0] == 2'b00;
    wire write_access = |mem_wstrb;
    wire a_select = aligned && offset >= 32'h10 && offset <= 32'h4c;
    wire b_select = aligned && offset >= 32'h50 && offset <= 32'h8c;
    wire c_select = aligned && offset >= 32'h90 && offset <= 32'hcc;
    // A/B/C start offsets share the same low word-index nibble (4).
    wire [3:0] element_addr = offset[5:2] - 4'd4;
    wire busy, done;
    wire signed [23:0] result_data;
    wire load_we = accept && mem_wstrb[0] && (a_select || b_select);
    wire start = accept && aligned && offset == 0 &&
                 mem_wstrb[0] && mem_wdata[0];

    accelerator_4x4 u_accelerator (
        .clk(clk), .rst(rst), .load_we(load_we), .load_b(b_select),
        .load_addr(element_addr), .load_data(mem_wdata[7:0]),
        .start(start), .busy(busy), .done(done),
        .result_addr(element_addr), .result_data(result_data)
    );

    always @(posedge clk) begin
        if (rst) begin
            served <= 0;
            mem_ready <= 0;
            mem_rdata <= 0;
        end else begin
            mem_ready <= 0;
            if (!mem_valid) served <= 0;
            if (accept) begin
                served <= 1;
                mem_ready <= 1;
                mem_rdata <= 0;
                if (!write_access && aligned) begin
                    if (offset == 32'h04)
                        mem_rdata <= {30'b0, done, busy};
                    else if (c_select)
                        mem_rdata <= {{8{result_data[23]}}, result_data};
                end
            end
        end
    end
endmodule
