// CPU + accelerator interconnect. RAM and simulation reporting are external.
// See sw/PROCESSOR_ACCELERATOR.md for the address map and firmware flow.
module picorv32_accelerator (
    input wire clk,
    input wire rst,
    output wire trap,
    output wire ram_valid,
    output wire [31:0] ram_addr,
    output wire [31:0] ram_wdata,
    output wire [3:0] ram_wstrb,
    input wire ram_ready,
    input wire [31:0] ram_rdata
);
    wire mem_valid;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0] mem_wstrb;
    wire mmio_select = mem_addr[31:8] == 24'h100000;
    wire mmio_ready;
    wire [31:0] mmio_rdata;
    reg mmio_gap;

    // Insert a valid-low edge after each peripheral acknowledgement, even
    // if the CPU presents another request without lowering its own valid.
    always @(posedge clk) begin
        if (rst) mmio_gap <= 0;
        else mmio_gap <= mmio_ready;
    end

    assign ram_valid = mem_valid && !mmio_select && !rst;
    assign ram_addr = mem_addr;
    assign ram_wdata = mem_wdata;
    assign ram_wstrb = mem_wstrb;

    picorv32 #(
        .ENABLE_MUL(1), .ENABLE_DIV(1), .STACKADDR(32'h00010000)
    ) u_cpu (
        .clk(clk), .resetn(!rst), .trap(trap),
        .mem_valid(mem_valid), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_ready(mmio_select ? (mmio_ready && !mmio_gap) : ram_ready),
        .mem_rdata(mmio_select ? mmio_rdata : ram_rdata),
        .irq(32'b0), .pcpi_wr(1'b0), .pcpi_rd(32'b0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    accelerator_mmio u_mmio (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid && mmio_select && !mmio_gap && !rst),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_ready(mmio_ready), .mem_rdata(mmio_rdata)
    );
endmodule
