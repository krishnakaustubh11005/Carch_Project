// Runs one accelerator job through its phases:
//   IDLE --job_start--> FETCH_A --> FETCH_B --> COMPUTE --> COPY --> IDLE
// Each phase pulses its block's start in its first cycle and waits for that
// block's done. job_done pulses for one cycle when the copy has finished.
//
// FETCH_A: fetch unit copies A (rows M, cols K) into scratchpad_a.
// FETCH_B: fetch unit copies B (rows K, cols N) into scratchpad_b (fu_sel_b).
// COMPUTE: tile sequencer with ceil(M/4)-1, ceil(N/4)-1 and K-1. Its done is
//   a level that stays high from the previous job until a new start is
//   accepted, so it is ignored in COMPUTE's first cycle.
// COPY: copier writes the M x N result to C_ADDR (rows_ready = M in v1);
//   copy_phase hands RAM port B to the copier.
//
// abort (one cycle) returns to IDLE without job_done; sub_rst resets the
// fetch unit, sequencer (and array) and copier in the same cycle.
// fetch_cycles counts FETCH_A + FETCH_B cycles and compute_cycles counts
// COMPUTE + COPY cycles of the current or last job; both clear on job_start.
module job_controller #(
    parameter DIM_W = 6,
    parameter RAM_ADDR_W = 13
) (
    input  wire clk,
    input  wire rst,
    input  wire job_start,
    input  wire abort,
    input  wire [DIM_W:0] m,
    input  wire [DIM_W:0] n,
    input  wire [DIM_W:0] k,
    input  wire [RAM_ADDR_W+1:0] a_addr,
    input  wire [RAM_ADDR_W+1:0] b_addr,
    input  wire [RAM_ADDR_W+1:0] c_addr,

    output wire busy,
    output reg  job_done,
    output reg  [31:0] fetch_cycles,
    output reg  [31:0] compute_cycles,
    output wire sub_rst,

    // Fetch unit.
    output reg  fu_start,
    output wire [RAM_ADDR_W+1:0] fu_base,
    output wire [DIM_W:0] fu_rows,
    output wire [DIM_W:0] fu_cols,
    output wire fu_sel_b,
    input  wire fu_done,

    // Tile sequencer.
    output reg  seq_start,
    output wire [DIM_W-3:0] row_groups_m1,
    output wire [DIM_W-3:0] col_groups_m1,
    output wire [DIM_W-1:0] k_m1,
    input  wire seq_done,

    // Copier.
    output reg  cp_start,
    output wire [RAM_ADDR_W-1:0] cp_word_addr,
    output wire [DIM_W:0] cp_rows_ready,
    input  wire cp_done,
    output wire copy_phase
);
    localparam [2:0] IDLE = 3'd0, FETCH_A = 3'd1, FETCH_B = 3'd2,
                     COMPUTE = 3'd3, COPY = 3'd4;

    reg [2:0] state;

    assign busy = (state != IDLE);
    assign sub_rst = rst || abort;

    assign fu_sel_b = (state == FETCH_B);
    assign fu_base = fu_sel_b ? b_addr : a_addr;
    assign fu_rows = fu_sel_b ? k : m;
    assign fu_cols = fu_sel_b ? n : k;

    // ceil(x/4) - 1 = (x - 1) div 4, for x in 1..2**DIM_W.
    wire [DIM_W:0] m_m1 = m - 1'b1;
    wire [DIM_W:0] n_m1 = n - 1'b1;
    wire [DIM_W:0] k_less = k - 1'b1;
    assign row_groups_m1 = m_m1[DIM_W-1:2];
    assign col_groups_m1 = n_m1[DIM_W-1:2];
    assign k_m1 = k_less[DIM_W-1:0];

    assign cp_word_addr = c_addr[RAM_ADDR_W+1:2];
    assign cp_rows_ready = m;
    assign copy_phase = (state == COPY);

    always @(posedge clk) begin
        if (rst || abort) begin
            state <= IDLE;
            job_done <= 1'b0;
            fu_start <= 1'b0;
            seq_start <= 1'b0;
            cp_start <= 1'b0;
            if (rst) begin
                fetch_cycles <= 32'd0;
                compute_cycles <= 32'd0;
            end
        end else begin
            job_done <= 1'b0;
            fu_start <= 1'b0;
            seq_start <= 1'b0;
            cp_start <= 1'b0;
            case (state)
                IDLE: begin
                    if (job_start) begin
                        fetch_cycles <= 32'd0;
                        compute_cycles <= 32'd0;
                        fu_start <= 1'b1;
                        state <= FETCH_A;
                    end
                end
                FETCH_A: begin
                    fetch_cycles <= fetch_cycles + 1'b1;
                    if (fu_done) begin
                        fu_start <= 1'b1;
                        state <= FETCH_B;
                    end
                end
                FETCH_B: begin
                    fetch_cycles <= fetch_cycles + 1'b1;
                    if (fu_done) begin
                        seq_start <= 1'b1;
                        state <= COMPUTE;
                    end
                end
                COMPUTE: begin
                    compute_cycles <= compute_cycles + 1'b1;
                    if (seq_done && !seq_start) begin
                        cp_start <= 1'b1;
                        state <= COPY;
                    end
                end
                COPY: begin
                    compute_cycles <= compute_cycles + 1'b1;
                    if (cp_done) begin
                        job_done <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
