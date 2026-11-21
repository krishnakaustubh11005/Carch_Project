// Memory-mapped registers of the matmul accelerator (docs/ACCELERATOR_PLAN.md
// section 4). Full 32-bit word accesses; byte strobes are not supported.
//
// Bus: bus_valid with bus_write and the byte offset bus_addr. Writes take
// effect on the clock edge; reads are combinational (bus_rdata is valid in
// the same cycle as bus_valid). Unmapped offsets read 0 and ignore writes.
//
// STAGING and ACTIVE: the CPU writes M, N, K, A_ADDR, B_ADDR and C_ADDR at any
// time. An accepted START copies them into the ACTIVE outputs and pulses
// job_start, so register writes never affect a running job.
//
// START is checked in this order; a rejected START sets STATUS.ERROR and
// ERR_CODE and starts nothing:
//   4 busy, 1 M/N/K outside 1..MAX_DIM, 2 C_ADDR not a multiple of 4,
//   5 A, B or C extends past the end of the data RAM.
// ABORT wins over START in the same write. An accepted START clears DONE.
//
// Timing: the START write is checked on the following clock (start_req), so
// the M*K, K*N and M*N products come from registers instead of being
// computed in the same cycle as the add and compare. The staging registers
// cannot change between the START write and its check (one write per
// cycle), so the registered products always match. busy includes a pending
// START, and an ABORT cancels it.
//
// irq = STATUS.DONE & IRQ_EN[0], a level. The CPU clears it by writing 1 to
// STATUS bit 2 (DONE); a DONE set in the same cycle wins over the clear.
module accel_regs #(
    parameter DIM_W = 6,
    parameter RAM_ADDR_W = 13
) (
    input  wire clk,
    input  wire rst,

    input  wire bus_valid,
    input  wire bus_write,
    input  wire [7:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,

    input  wire ctrl_busy,
    input  wire job_done,
    input  wire [31:0] fetch_cycles,
    input  wire [31:0] compute_cycles,

    output reg job_start,
    output reg abort,
    output reg [DIM_W:0] act_m,
    output reg [DIM_W:0] act_n,
    output reg [DIM_W:0] act_k,
    output reg [RAM_ADDR_W+1:0] act_a_addr,
    output reg [RAM_ADDR_W+1:0] act_b_addr,
    output reg [RAM_ADDR_W+1:0] act_c_addr,
    output wire irq
);
    localparam [5:0] R_ID = 6'h00, R_CAPS = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                     R_ERR = 6'h04, R_JOBS = 6'h05, R_FETCH = 6'h06, R_COMPUTE = 6'h07,
                     R_M = 6'h08, R_N = 6'h09, R_K = 6'h0A,
                     R_A = 6'h0B, R_B = 6'h0C, R_C = 6'h0D, R_IRQ = 6'h0E;
    localparam [31:0] ID_VALUE = 32'h4D4D3434;   // "MM44"
    localparam MAX_DIM = 1 << DIM_W;
    // [7:0] MAX_DIM, [11:8] array size 4, [15:12] queue depth 0.
    localparam [31:0] CAPS_VALUE = {16'd0, 4'd0, 4'd4, 8'd0} | MAX_DIM;
    localparam [32:0] RAM_BYTES = 33'd1 << (RAM_ADDR_W + 2);

    // Staging set, full 32 bits so out-of-range values can be detected.
    reg [31:0] m_s, n_s, k_s, a_s, b_s, c_s;
    reg irq_en;
    reg done_bit, err_bit;
    reg [3:0] err_code;
    reg [31:0] jobs_done;

    wire [5:0] reg_index = bus_addr[7:2];
    wire wr = bus_valid && bus_write;

    // A START write waiting for its check on the next clock, and whether
    // the accelerator was busy when it was written.
    reg start_req;
    reg start_req_busy;
    wire busy_now = ctrl_busy || job_start || start_req;

    // Products of the staging dimensions, one clock behind the staging set.
    reg [2*DIM_W+1:0] a_bytes, b_bytes;
    reg [2*DIM_W+3:0] c_bytes;
    always @(posedge clk) begin
        a_bytes <= m_s[DIM_W:0] * k_s[DIM_W:0];
        b_bytes <= k_s[DIM_W:0] * n_s[DIM_W:0];
        c_bytes <= {m_s[DIM_W:0] * n_s[DIM_W:0], 2'b00};
    end

    // START checks on the staging set, evaluated while start_req is set.
    wire dim_ok = (m_s >= 1) && (m_s <= MAX_DIM) && (n_s >= 1) && (n_s <= MAX_DIM)
               && (k_s >= 1) && (k_s <= MAX_DIM);
    wire range_ok = ({1'b0, a_s} + a_bytes <= RAM_BYTES)
                 && ({1'b0, b_s} + b_bytes <= RAM_BYTES)
                 && ({1'b0, c_s} + c_bytes <= RAM_BYTES);
    wire [3:0] start_err = start_req_busy ? 4'd4 :
                           !dim_ok       ? 4'd1 :
                           (c_s[1:0] != 2'b00) ? 4'd2 :
                           !range_ok     ? 4'd5 : 4'd0;

    assign irq = done_bit && irq_en;

    always @* begin
        case (reg_index)
            R_ID:      bus_rdata = ID_VALUE;
            R_CAPS:    bus_rdata = CAPS_VALUE;
            R_STATUS:  bus_rdata = {28'd0, err_bit, done_bit, 1'b0, busy_now};
            R_ERR:     bus_rdata = {28'd0, err_code};
            R_JOBS:    bus_rdata = jobs_done;
            R_FETCH:   bus_rdata = fetch_cycles;
            R_COMPUTE: bus_rdata = compute_cycles;
            R_M:       bus_rdata = m_s;
            R_N:       bus_rdata = n_s;
            R_K:       bus_rdata = k_s;
            R_A:       bus_rdata = a_s;
            R_B:       bus_rdata = b_s;
            R_C:       bus_rdata = c_s;
            R_IRQ:     bus_rdata = {31'd0, irq_en};
            default:   bus_rdata = 32'd0;   // CTRL reads 0, unmapped reads 0
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            m_s <= 0; n_s <= 0; k_s <= 0; a_s <= 0; b_s <= 0; c_s <= 0;
            irq_en <= 1'b0;
            done_bit <= 1'b0;
            err_bit <= 1'b0;
            err_code <= 4'd0;
            jobs_done <= 32'd0;
            job_start <= 1'b0;
            abort <= 1'b0;
            start_req <= 1'b0;
            start_req_busy <= 1'b0;
            act_m <= 0; act_n <= 0; act_k <= 0;
            act_a_addr <= 0; act_b_addr <= 0; act_c_addr <= 0;
        end else begin
            job_start <= 1'b0;
            abort <= 1'b0;
            start_req <= 1'b0;

            // Check the START written on the previous clock.
            if (start_req) begin
                if (start_err != 4'd0) begin
                    err_bit <= 1'b1;
                    err_code <= start_err;
                end else begin
                    job_start <= 1'b1;
                    done_bit <= 1'b0;
                    act_m <= m_s[DIM_W:0];
                    act_n <= n_s[DIM_W:0];
                    act_k <= k_s[DIM_W:0];
                    act_a_addr <= a_s[RAM_ADDR_W+1:0];
                    act_b_addr <= b_s[RAM_ADDR_W+1:0];
                    act_c_addr <= c_s[RAM_ADDR_W+1:0];
                end
            end

            if (wr) begin
                case (reg_index)
                    R_M:   m_s <= bus_wdata;
                    R_N:   n_s <= bus_wdata;
                    R_K:   k_s <= bus_wdata;
                    R_A:   a_s <= bus_wdata;
                    R_B:   b_s <= bus_wdata;
                    R_C:   c_s <= bus_wdata;
                    R_IRQ: irq_en <= bus_wdata[0];
                    R_STATUS: begin
                        if (bus_wdata[2]) done_bit <= 1'b0;
                        if (bus_wdata[3]) err_bit <= 1'b0;
                    end
                    R_CTRL: begin
                        if (bus_wdata[1]) begin
                            // ABORT also cancels a START still being checked.
                            abort <= 1'b1;
                            job_start <= 1'b0;
                        end else if (bus_wdata[0]) begin
                            start_req <= 1'b1;
                            start_req_busy <= busy_now;
                        end
                    end
                    default: ;
                endcase
            end
            // After the STATUS write, so a finishing job wins over a clear.
            if (job_done) begin
                done_bit <= 1'b1;
                jobs_done <= jobs_done + 1'b1;
            end
        end
    end
endmodule
