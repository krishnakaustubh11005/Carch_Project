// System top: PicoRV32 CPU + shared 64 KB data RAM + matmul accelerator.
//
// CPU address map (full decode; see docs/CPU_INTEGRATION_CHECKLIST.md):
//   0x0000_0000 - 0x0000_FFFF  RAM (port A; port B belongs to the accelerator)
//   0x4000_0000 - 0x4000_00FF  matmul_accel registers
//   0x8000_0000 - 0x8000_00FF  result port (one register, every offset aliases)
//   anything else              unmapped: reads 0, writes ignored, bus_error
//
// Handshake: PicoRV32 holds mem_valid until mem_ready.
//   RAM: one-cycle read latency, so ready comes one cycle late. ram_ready marks
//     that cycle; en_a is blocked in it so one request is one RAM access.
//     The read mux selects RAM data with the registered ram_ready.
//   Accelerator, result port, unmapped: ready in the same cycle.
//
// Only full-word stores (wstrb 1111) reach the accelerator; PicoRV32 copies a
// byte or half-word into every lane, so `sb 2` to CTRL would otherwise ABORT.
// A partial store there is dropped and sets bus_error.
//
// Result port: firmware writes a code (e.g. 1 = pass, 2+ = fail number);
// result holds it and result_valid pulses for one cycle. Reads at offset 0
// return result; reads at offset 4*i (i = 1..CFG_WORDS) return cfg_in word i-1,
// a read-only configuration the board wrapper supplies (fpga/fpga_top.v, from
// the VIO); other offsets read 0. Writes to any offset go to result.
//
// bus_error is sticky until reset. irq: the accelerator drives irq[3]
// (bits 0-2 are PicoRV32's timer, ebreak and bus error).
module soc_top #(
    parameter FIRMWARE = "",            // $readmemh file loaded into the RAM
    parameter RAM_ADDR_W = 14,          // 2^14 words = 64 KB
    parameter [0:0] ENABLE_IRQ = 0,
    parameter CFG_WORDS = 10,           // read-only words at 0x8000_0004 onwards
    parameter [0:0] ENABLE_ACCEL = 1    // 0: CPU-only baseline; 0x4000_0000 reads 0, writes ignored
) (
    input  wire clk,
    input  wire rst,                    // synchronous, active high
    input  wire [32*CFG_WORDS-1:0] cfg_in,  // word i-1 at 0x8000_0000 + 4*i; tie to 0 if unused

    output wire trap,                   // CPU halted on a bad access or instruction
    output reg  [31:0] result,
    output reg  result_valid,
    output reg  bus_error
);
    localparam [31:0] ACCEL_BASE = 32'h4000_0000;
    localparam [31:0] IO_BASE = 32'h8000_0000;

    // ---------------------------------------------------------------- CPU
    wire        mem_valid, mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;
    wire        accel_irq;

    picorv32 #(
        .ENABLE_COUNTERS(1),
        .ENABLE_FAST_MUL(1),
        .ENABLE_DIV(0),
        .COMPRESSED_ISA(0),
        .CATCH_MISALIGN(1),
        .CATCH_ILLINSN(1),
        .REGS_INIT_ZERO(1),
        .ENABLE_IRQ(ENABLE_IRQ),
        .ENABLE_IRQ_QREGS(1),
        .ENABLE_IRQ_TIMER(0),
        .LATCHED_IRQ(32'hFFFF_FFF7),    // irq[3] (accelerator) is level-sensitive
        .PROGADDR_RESET(32'h0000_0000),
        .PROGADDR_IRQ(32'h0000_0010),
        .STACKADDR(32'h0000_8000)
    ) u_cpu (
        .clk(clk), .resetn(!rst), .trap(trap),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq({28'd0, accel_irq, 3'b000}), .eoi(),
        .trace_valid(), .trace_data()
    );

    // ---------------------------------------------------------------- decoder
    wire sel_ram   = (mem_addr[31:RAM_ADDR_W+2] == 0);
    wire sel_accel = (mem_addr[31:8] == ACCEL_BASE[31:8]);
    wire sel_io    = (mem_addr[31:8] == IO_BASE[31:8]);
    wire unmapped  = !sel_ram && !sel_accel && !sel_io;

    wire is_write = (mem_wstrb != 4'b0000);
    wire accel_partial = is_write && (mem_wstrb != 4'b1111);

    // ---------------------------------------------------------------- RAM
    reg ram_ready;
    wire ram_req = mem_valid && sel_ram && !ram_ready;
    wire [31:0] ram_rdata_a;

    wire ram_en_b;
    wire [3:0] ram_we_b;
    wire [RAM_ADDR_W-1:0] ram_addr_b;
    wire [31:0] ram_wdata_b, ram_rdata_b;

    dual_port_ram #(.ADDR_W(RAM_ADDR_W), .DATA_W(32), .INIT_FILE(FIRMWARE)) u_ram (
        .clk(clk),
        .en_a(ram_req), .we_a(mem_wstrb), .addr_a(mem_addr[RAM_ADDR_W+1:2]),
        .wdata_a(mem_wdata), .rdata_a(ram_rdata_a),
        .en_b(ram_en_b), .we_b(ram_we_b), .addr_b(ram_addr_b),
        .wdata_b(ram_wdata_b), .rdata_b(ram_rdata_b)
    );

    // ---------------------------------------------------------------- accelerator
    wire [31:0] accel_rdata;

    generate if (ENABLE_ACCEL) begin : g_accel
        matmul_accel #(.DIM_W(6), .RAM_ADDR_W(RAM_ADDR_W)) u_accel (
            .clk(clk), .rst(rst),
            .bus_valid(mem_valid && sel_accel && !accel_partial),
            .bus_write(is_write), .bus_addr(mem_addr[7:0]), .bus_wdata(mem_wdata),
            .bus_rdata(accel_rdata), .bus_ready(),
            .irq(accel_irq),
            .ram_en(ram_en_b), .ram_we(ram_we_b), .ram_addr(ram_addr_b),
            .ram_wdata(ram_wdata_b), .ram_rdata(ram_rdata_b)
        );
    end else begin : g_no_accel
        // Baseline: the register window stays decoded (ID reads 0, so the
        // firmware knows there is no accelerator); RAM port B is idle.
        assign accel_rdata = 32'd0;
        assign accel_irq = 1'b0;
        assign ram_en_b = 1'b0;
        assign ram_we_b = 4'd0;
        assign ram_addr_b = {RAM_ADDR_W{1'b0}};
        assign ram_wdata_b = 32'd0;
    end endgenerate

    // ---------------------------------------------------------------- handshake and read mux
    assign mem_ready = ram_ready || (mem_valid && !sel_ram);
    reg [31:0] io_rdata;
    integer cfg_index;
    always @(*) begin
        io_rdata = (mem_addr[7:2] == 6'd0) ? result : 32'd0;
        for (cfg_index = 0; cfg_index < CFG_WORDS; cfg_index = cfg_index + 1)
            if (mem_addr[7:2] == cfg_index + 1)
                io_rdata = cfg_in[32*cfg_index +: 32];
    end

    assign mem_rdata = ram_ready ? ram_rdata_a :
                       sel_accel ? accel_rdata :
                       sel_io    ? io_rdata : 32'd0;

    always @(posedge clk) begin
        if (rst) begin
            ram_ready <= 1'b0;
            result <= 32'd0;
            result_valid <= 1'b0;
            bus_error <= 1'b0;
        end else begin
            ram_ready <= ram_req;
            result_valid <= 1'b0;
            if (mem_valid && sel_io && is_write) begin
                result <= mem_wdata;
                result_valid <= 1'b1;
            end
            if (mem_valid && (unmapped || (sel_accel && accel_partial)))
                bus_error <= 1'b1;
        end
    end
endmodule
