// Runs C (M'xN') = A (M'xK) x B (KxN') on the fixed 4x4 array, one 4x4 output
// tile at a time, with no gaps between tiles. M' and N' are multiples of 4;
// the loader writes zero padding into the scratchpads (decision D-007).
//
// Job contract:
//   row_groups_m1 = M'/4 - 1, col_groups_m1 = N'/4 - 1, k_m1 = K - 1.
//   They are latched on a start pulse accepted while idle; start is ignored
//   while busy. done is a level: it rises after the last C write has been
//   committed and stays high until the next accepted start.
//
// Schedule (decisions D-006, D-007):
//   Tiles run gi-outer, gj-inner. Each tile occupies P = max(K, 4) slots:
//   slots 0..K-1 read A column k / B row k, slots K..P-1 are empty beats.
//   drain_in accompanies slot 0 of every tile except the first; the end
//   marker is one more drain exactly one period after the last tile starts.
//   Keeping every drain P >= 4 clocks apart means two results never reach
//   the same C bank (row) on the same clock. en is held high: the array
//   never stalls.
//
// Pipeline:
//   Stage 0 (this module's counters) drives the scratchpad read addresses.
//   The scratchpads answer one clock later, so valid, drain and the tile tag
//   are registered once (stage 1) to arrive with their data at the array.
//
// C collection:
//   With the drain, the closed tile's {gi, gj} tag enters a 7-stage shift
//   register that moves like the array's internal drain pulse. PE(r,c)
//   publishes r+c clocks after PE(0,0), so its tag is at stage r+c. Bank r
//   writes the one PE of row r whose results_valid bit is set at
//   {gi, gj, c}, with the 24-bit result sign-extended to 32 bits.
//
// DIM_W must be at most 8 so that K never exceeds the array's K_MAX=256.
module tile_sequencer #(
    parameter DIM_W = 6
) (
    input  wire clk,
    input  wire rst,

    input  wire start,
    input  wire [DIM_W-3:0] row_groups_m1,
    input  wire [DIM_W-3:0] col_groups_m1,
    input  wire [DIM_W-1:0] k_m1,
    output wire busy,
    output reg  done,

    // Scratchpad A read port: lane r = A[4*a_rd_group + r][a_rd_k].
    output wire a_rd_en,
    output wire [DIM_W-3:0] a_rd_group,
    output wire [DIM_W-1:0] a_rd_k,
    input  wire [31:0] a_rd_data,

    // Scratchpad B read port: lane c = B[b_rd_k][4*b_rd_group + c].
    output wire b_rd_en,
    output wire [DIM_W-3:0] b_rd_group,
    output wire [DIM_W-1:0] b_rd_k,
    input  wire [31:0] b_rd_data,

    // C store write ports, one per bank (bank = C row mod 4).
    output wire [3:0] c_wr_en,
    output wire [4*(2*DIM_W-2)-1:0] c_wr_addr,
    output wire [127:0] c_wr_data
);
    localparam GROUP_W = DIM_W - 2;
    localparam TAG_W = 2*GROUP_W;
    localparam C_ADDR_W = 2*DIM_W - 2;
    // Smallest tile period minus one: four slots per tile.
    localparam [DIM_W-1:0] MIN_PERIOD_M1 = 3;
    // Clocks after the end-marker slot until PE(3,3)'s write has committed:
    // one for the scratchpad stage and seven for the drain to reach PE(3,3)
    // and be published.
    localparam [2:0] FLUSH_LAST = 3'd7;

    localparam [2:0] IDLE  = 3'd0;
    localparam [2:0] CLEAR = 3'd1;
    localparam [2:0] RUN   = 3'd2;
    localparam [2:0] ENDM  = 3'd3;
    localparam [2:0] FLUSH = 3'd4;

    reg [2:0] state;

    // Latched job configuration.
    reg [GROUP_W-1:0] row_last;
    reg [GROUP_W-1:0] col_last;
    reg [DIM_W-1:0] k_last;
    reg [DIM_W-1:0] period_last;

    // Stage 0 counters: slot within the tile period, then column and row group.
    reg [DIM_W-1:0] slot;
    reg [GROUP_W-1:0] gi;
    reg [GROUP_W-1:0] gj;
    reg first_tile;
    reg [TAG_W-1:0] close_tag;
    reg [2:0] flush_count;

    wire issue_valid = (state == RUN) && (slot <= k_last);
    wire issue_drain = ((state == RUN) && (slot == {DIM_W{1'b0}}) && !first_tile) ||
                       (state == ENDM);

    assign busy = (state != IDLE);
    assign a_rd_en = issue_valid;
    assign a_rd_group = gi;
    assign a_rd_k = slot;
    assign b_rd_en = issue_valid;
    assign b_rd_group = gj;
    assign b_rd_k = slot;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            done <= 1'b0;
            row_last <= {GROUP_W{1'b0}};
            col_last <= {GROUP_W{1'b0}};
            k_last <= {DIM_W{1'b0}};
            period_last <= MIN_PERIOD_M1;
            slot <= {DIM_W{1'b0}};
            gi <= {GROUP_W{1'b0}};
            gj <= {GROUP_W{1'b0}};
            first_tile <= 1'b1;
            close_tag <= {TAG_W{1'b0}};
            flush_count <= 3'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        row_last <= row_groups_m1;
                        col_last <= col_groups_m1;
                        k_last <= k_m1;
                        period_last <= (k_m1 < MIN_PERIOD_M1) ? MIN_PERIOD_M1 : k_m1;
                        done <= 1'b0;
                        state <= CLEAR;
                    end
                end

                // The array's clear is asserted for this one clock.
                CLEAR: begin
                    slot <= {DIM_W{1'b0}};
                    gi <= {GROUP_W{1'b0}};
                    gj <= {GROUP_W{1'b0}};
                    first_tile <= 1'b1;
                    state <= RUN;
                end

                RUN: begin
                    if (slot == period_last) begin
                        // Remember the tile being closed: the next drain
                        // (next tile's slot 0 or the end marker) carries it.
                        slot <= {DIM_W{1'b0}};
                        first_tile <= 1'b0;
                        close_tag <= {gi, gj};
                        if (gj == col_last) begin
                            gj <= {GROUP_W{1'b0}};
                            if (gi == row_last)
                                state <= ENDM;
                            else
                                gi <= gi + 1'b1;
                        end else begin
                            gj <= gj + 1'b1;
                        end
                    end else begin
                        slot <= slot + 1'b1;
                    end
                end

                // End marker: one empty beat with drain, a full period after
                // the last tile started.
                ENDM: begin
                    flush_count <= 3'd0;
                    state <= FLUSH;
                end

                FLUSH: begin
                    if (flush_count == FLUSH_LAST) begin
                        done <= 1'b1;
                        state <= IDLE;
                    end else begin
                        flush_count <= flush_count + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // Stage 1: align control with the scratchpad data that arrives now.
    reg s1_valid;
    reg s1_drain;
    reg [TAG_W-1:0] s1_tag;
    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s1_drain <= 1'b0;
            s1_tag <= {TAG_W{1'b0}};
        end else begin
            s1_valid <= issue_valid;
            s1_drain <= issue_drain;
            s1_tag <= close_tag;
        end
    end

    wire [383:0] results;
    wire [15:0] results_valid;

    systolic_4_4_array u_array (
        .clk(clk),
        .rst(rst),
        .clear(state == CLEAR),
        .en(1'b1),
        .a_in(a_rd_data),
        .b_in(b_rd_data),
        .a_valid_in({4{s1_valid}}),
        .b_valid_in({4{s1_valid}}),
        .drain_in(s1_drain),
        .results(results),
        .results_valid(results_valid)
    );

    // Tag shift register: stage d holds the tag of the drain that entered
    // the array d+1 clocks ago, which is when PEs with row+column = d
    // show results_valid for it.
    reg [TAG_W-1:0] tag_shift [0:6];
    integer stage;
    always @(posedge clk) begin
        if (rst) begin
            for (stage = 0; stage < 7; stage = stage + 1)
                tag_shift[stage] <= {TAG_W{1'b0}};
        end else begin
            tag_shift[0] <= s1_tag;
            for (stage = 1; stage < 7; stage = stage + 1)
                tag_shift[stage] <= tag_shift[stage-1];
        end
    end

    // One write port per bank. With P >= 4 at most one PE of a row
    // publishes on any clock, so the row's valid bits are one-hot or zero.
    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : g_bank
            wire [3:0] row_valid = results_valid[4*bank +: 4];
            reg [1:0] column;
            always @(*) begin
                case (row_valid)
                    4'b0010: column = 2'd1;
                    4'b0100: column = 2'd2;
                    4'b1000: column = 2'd3;
                    default: column = 2'd0;
                endcase
            end

            wire [23:0] result = results[24*(4*bank + column) +: 24];
            wire [TAG_W-1:0] tag = tag_shift[bank + column];

            assign c_wr_en[bank] = |row_valid;
            // {gi, gj, c} = 64*gi + 4*gj + c for DIM_W=6: no adder needed.
            assign c_wr_addr[C_ADDR_W*bank +: C_ADDR_W] = {tag, column};
            assign c_wr_data[32*bank +: 32] = {{8{result[23]}}, result};
        end
    endgenerate
endmodule
