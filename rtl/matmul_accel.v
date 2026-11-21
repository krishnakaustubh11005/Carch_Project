// Top level of the matmul accelerator: C (M x N) = A (M x K) x B (K x N),
// signed INT8 inputs, 32-bit sign-extended results, M, N, K in 1..2**DIM_W.
//
//   CPU bus --> accel_regs --> job_controller --> fetch_unit --> scratchpad_a/b
//                                     |                              |
//                                     +--> tile_sequencer (array) <--+
//                                     |          |
//                                     |       c_store --> c_copier
//                                     +---------------------- RAM port mux
//
// The data RAM is outside this module and shared with the CPU: the CPU uses
// its port A, this accelerator its port B (ram_*), word-addressed, one-cycle
// read latency. Port B belongs to the fetch unit in FETCH_A/FETCH_B and to the
// copier in COPY; the two never overlap.
//
// CPU bus: see accel_regs. bus_ready equals bus_valid (no wait states).
module matmul_accel #(
    parameter DIM_W = 6,
    parameter RAM_ADDR_W = 13
) (
    input  wire clk,
    input  wire rst,

    input  wire bus_valid,
    input  wire bus_write,
    input  wire [7:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output wire [31:0] bus_rdata,
    output wire bus_ready,
    output wire irq,

    output wire ram_en,
    output wire [3:0] ram_we,
    output wire [RAM_ADDR_W-1:0] ram_addr,
    output wire [31:0] ram_wdata,
    input  wire [31:0] ram_rdata
);
    localparam GROUP_W = DIM_W - 2;
    localparam C_ADDR_W = 2*DIM_W - 2;

    assign bus_ready = bus_valid;

    // Registers <-> controller.
    wire job_start, abort, ctrl_busy, job_done;
    wire [31:0] fetch_cycles, compute_cycles;
    wire [DIM_W:0] act_m, act_n, act_k;
    wire [RAM_ADDR_W+1:0] act_a_addr, act_b_addr, act_c_addr;

    accel_regs #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) u_regs (
        .clk(clk), .rst(rst),
        .bus_valid(bus_valid), .bus_write(bus_write), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .ctrl_busy(ctrl_busy), .job_done(job_done),
        .fetch_cycles(fetch_cycles), .compute_cycles(compute_cycles),
        .job_start(job_start), .abort(abort),
        .act_m(act_m), .act_n(act_n), .act_k(act_k),
        .act_a_addr(act_a_addr), .act_b_addr(act_b_addr), .act_c_addr(act_c_addr),
        .irq(irq)
    );

    // Controller <-> blocks.
    wire sub_rst;
    wire fu_start, fu_sel_b, fu_done, fu_busy;
    wire [RAM_ADDR_W+1:0] fu_base;
    wire [DIM_W:0] fu_rows, fu_cols;
    wire seq_start, seq_done, seq_busy;
    wire [GROUP_W-1:0] row_groups_m1, col_groups_m1;
    wire [DIM_W-1:0] k_m1;
    wire cp_start, cp_done, cp_busy, copy_phase;
    wire [RAM_ADDR_W-1:0] cp_word_addr;
    wire [DIM_W:0] cp_rows_ready;

    job_controller #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) u_ctrl (
        .clk(clk), .rst(rst), .job_start(job_start), .abort(abort),
        .m(act_m), .n(act_n), .k(act_k),
        .a_addr(act_a_addr), .b_addr(act_b_addr), .c_addr(act_c_addr),
        .busy(ctrl_busy), .job_done(job_done),
        .fetch_cycles(fetch_cycles), .compute_cycles(compute_cycles),
        .sub_rst(sub_rst),
        .fu_start(fu_start), .fu_base(fu_base), .fu_rows(fu_rows), .fu_cols(fu_cols),
        .fu_sel_b(fu_sel_b), .fu_done(fu_done),
        .seq_start(seq_start), .row_groups_m1(row_groups_m1),
        .col_groups_m1(col_groups_m1), .k_m1(k_m1), .seq_done(seq_done),
        .cp_start(cp_start), .cp_word_addr(cp_word_addr), .cp_rows_ready(cp_rows_ready),
        .cp_done(cp_done), .copy_phase(copy_phase)
    );

    // Fetch unit -> scratchpad A or B.
    wire fu_ram_en;
    wire [RAM_ADDR_W-1:0] fu_ram_addr;
    wire fu_wr_en;
    wire [DIM_W-1:0] fu_wr_row;
    wire [DIM_W-3:0] fu_wr_word;
    wire [31:0] fu_wr_data;

    fetch_unit #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) u_fetch (
        .clk(clk), .rst(sub_rst), .start(fu_start),
        .base_addr(fu_base), .rows(fu_rows), .cols(fu_cols),
        .ram_en(fu_ram_en), .ram_addr(fu_ram_addr), .ram_rdata(ram_rdata),
        .wr_en(fu_wr_en), .wr_row(fu_wr_row), .wr_word(fu_wr_word), .wr_data(fu_wr_data),
        .busy(fu_busy), .done(fu_done)
    );

    wire a_rd_en, b_rd_en;
    wire [GROUP_W-1:0] a_rd_group, b_rd_group;
    wire [DIM_W-1:0] a_rd_k, b_rd_k;
    wire [31:0] a_rd_data, b_rd_data;

    scratchpad_a #(.DIM_W(DIM_W)) u_scratchpad_a (
        .clk(clk),
        .wr_en(fu_wr_en && !fu_sel_b), .wr_row(fu_wr_row), .wr_word(fu_wr_word), .wr_data(fu_wr_data),
        .rd_en(a_rd_en), .rd_group(a_rd_group), .rd_k(a_rd_k), .rd_data(a_rd_data)
    );

    scratchpad_b #(.DIM_W(DIM_W)) u_scratchpad_b (
        .clk(clk),
        .wr_en(fu_wr_en && fu_sel_b), .wr_k(fu_wr_row), .wr_word(fu_wr_word), .wr_data(fu_wr_data),
        .rd_en(b_rd_en), .rd_group(b_rd_group), .rd_k(b_rd_k), .rd_data(b_rd_data)
    );

    // Tile sequencer (contains the 4x4 array) -> c_store.
    wire [3:0] c_wr_en;
    wire [4*C_ADDR_W-1:0] c_wr_addr;
    wire [127:0] c_wr_data;

    tile_sequencer #(.DIM_W(DIM_W)) u_seq (
        .clk(clk), .rst(sub_rst),
        .start(seq_start), .row_groups_m1(row_groups_m1), .col_groups_m1(col_groups_m1),
        .k_m1(k_m1), .busy(seq_busy), .done(seq_done),
        .a_rd_en(a_rd_en), .a_rd_group(a_rd_group), .a_rd_k(a_rd_k), .a_rd_data(a_rd_data),
        .b_rd_en(b_rd_en), .b_rd_group(b_rd_group), .b_rd_k(b_rd_k), .b_rd_data(b_rd_data),
        .c_wr_en(c_wr_en), .c_wr_addr(c_wr_addr), .c_wr_data(c_wr_data)
    );

    wire c_rd_en;
    wire [DIM_W-1:0] c_rd_row, c_rd_col;
    wire [31:0] c_rd_data;

    c_store #(.DIM_W(DIM_W)) u_c_store (
        .clk(clk),
        .wr_en(c_wr_en), .wr_addr(c_wr_addr), .wr_data(c_wr_data),
        .rd_en(c_rd_en), .rd_row(c_rd_row), .rd_col(c_rd_col), .rd_data(c_rd_data)
    );

    // Copier: c_store -> RAM.
    wire cp_ram_en;
    wire [3:0] cp_ram_we;
    wire [RAM_ADDR_W-1:0] cp_ram_addr;
    wire [31:0] cp_ram_wdata;

    c_copier #(.DIM_W(DIM_W), .RAM_ADDR_W(RAM_ADDR_W)) u_copier (
        .clk(clk), .rst(sub_rst), .start(cp_start),
        .c_word_addr(cp_word_addr), .m(act_m), .n(act_n), .rows_ready(cp_rows_ready),
        .rd_en(c_rd_en), .rd_row(c_rd_row), .rd_col(c_rd_col), .rd_data(c_rd_data),
        .ram_en(cp_ram_en), .ram_we(cp_ram_we), .ram_addr(cp_ram_addr), .ram_wdata(cp_ram_wdata),
        .busy(cp_busy), .done(cp_done)
    );

    // RAM port mux: the copier in COPY, the fetch unit otherwise (reads only).
    assign ram_en = copy_phase ? cp_ram_en : fu_ram_en;
    assign ram_we = copy_phase ? cp_ram_we : 4'b0000;
    assign ram_addr = copy_phase ? cp_ram_addr : fu_ram_addr;
    assign ram_wdata = cp_ram_wdata;
endmodule
