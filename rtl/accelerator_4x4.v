// Single-operation, register-backed wrapper around the fixed INT8 array.
// See rtl/ACCELERATOR_4X4.md for the clocked interface and timing contract.
module accelerator_4x4 (
    input wire clk,
    input wire rst,
    input wire load_we,
    input wire load_b,             // 0: A, 1: B
    input wire [3:0] load_addr,    // row-major element index
    input wire signed [7:0] load_data,
    input wire start,
    output wire busy,
    output reg done,
    input wire [3:0] result_addr,
    output wire signed [23:0] result_data
);
    localparam IDLE = 3'd0, CLEAR = 3'd1, FEED = 3'd2,
               DRAIN = 3'd3, COLLECT = 3'd4, DONE = 3'd5;
    reg [2:0] state;

    reg [1:0] k;
    reg signed [7:0] a_mem [0:15];
    reg signed [7:0] b_mem [0:15];
    reg signed [23:0] c_mem [0:15];
    reg [15:0] received;
    wire [383:0] results;
    wire [15:0] results_valid;
    reg [31:0] a_in, b_in;
    wire feeding = state == FEED;
    wire array_en = state == FEED || state == DRAIN || state == COLLECT;
    integer lane;
    integer index;
    assign busy = state != IDLE && state != DONE;
    assign result_data = c_mem[result_addr];

    // Source lanes are unskewed: the array supplies its own alignment delays.
    always @* begin
        a_in = 0;
        b_in = 0;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            a_in[8*lane +: 8] = a_mem[4*lane + k];
            b_in[8*lane +: 8] = b_mem[4*k + lane];
        end
    end

    systolic_4_4_array u_array (
        .clk(clk), .rst(rst), .clear(state == CLEAR), .en(array_en),
        .a_in(a_in), .b_in(b_in),
        .a_valid_in({4{feeding}}), .b_valid_in({4{feeding}}),
        .drain_in(state == DRAIN),
        .results(results), .results_valid(results_valid)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            done <= 0;
            k <= 0;
            received <= 0;
            for (index = 0; index < 16; index = index + 1) begin
                a_mem[index] <= 0;
                b_mem[index] <= 0;
                c_mem[index] <= 0;
            end
        end else begin
            // Writes have priority over start in idle/done. No ambiguous
            // same-edge final write/start; the caller starts on a later edge.
            if (!busy && load_we) begin
                if (load_b) b_mem[load_addr] <= load_data;
                else a_mem[load_addr] <= load_data;
            end

            // Capture throughout the active operation. Array outputs are
            // registered, so capture occurs one edge after PE publication.
            if (busy) begin
                received <= received | results_valid;
                for (index = 0; index < 16; index = index + 1)
                    if (results_valid[index])
                        c_mem[index] <= results[24*index +: 24];
            end

            case (state)
                IDLE, DONE: if (start && !load_we) begin
                    state <= CLEAR;
                    done <= 0;
                    received <= 0;
                    k <= 0;
                end
                CLEAR: state <= FEED;
                FEED: if (k == 3) state <= DRAIN;
                      else k <= k + 1'b1;
                DRAIN: state <= COLLECT;
                COLLECT: if (&(received | results_valid)) begin
                    state <= DONE;
                    done <= 1;
                end
                default: begin
                    state <= IDLE;
                    done <= 0;
                    received <= 0;
                end
            endcase
        end
    end
endmodule
