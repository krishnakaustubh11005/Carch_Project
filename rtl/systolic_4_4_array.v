// Fixed 4 x 4 output-stationary array built from the existing Booth/CSA PE.
// This first array has no parameters: signed INT8 operands, 24-bit results,
// and at most 256 accepted products per PE between tile boundaries.
//
// Input contract:
//   a_in[7:0] is row 0, [15:8] row 1, [23:16] row 2, [31:24] row 3.
//   b_in uses the same packing for columns 0 through 3.
//   At source step k, lane i supplies A[row_base+i][k] and lane j supplies
//   B[k][col_base+j]. The source orders operands; this block only skews timing.
//   Each byte is a signed two's-complement value. Packed buses are containers.
//
// Boundary contract:
//   drain_in accompanies the FIRST input step of the NEXT output tile.
//   Each PE publishes its old sum and may accept the next tile's first pair
//   on the same edge. Final publication uses a marker with invalid input lanes.
//   Keep en high for pipeline flush steps until the last diagonal publishes.
//
// Stall/reset contract:
//   en advances operands, valid bits, and boundary markers together.
//   Hold source data/control while stalled. Local drains are gated by en.
//   Synchronous rst/clear discard all in-flight work and zero all PE state.
//
// Output contract:
//   PE(row,column) drives results[24*(4*row+column) +: 24] and the matching
//   results_valid bit. Each 24-bit slice is signed; the aggregate bus is not.
//   Valid pulses last one clock even during a stall; collect on every clock.
//   There is no output ready handshake. Capture before the next publication.
// Functional verification is deferred until the contributor reviews this RTL.
module systolic_4_4_array (
    input  wire clk,
    input  wire rst,
    input  wire clear,
    input  wire en,
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    input  wire [3:0] a_valid_in,
    input  wire [3:0] b_valid_in,
    input  wire drain_in,
    output wire [383:0] results,
    output wire [15:0] results_valid
);

    // One byte and its valid bit form a 9-bit pipeline entry.
    wire [7:0] a_skewed [0:3];
    wire [7:0] b_skewed [0:3];
    wire [3:0] a_valid_skewed;
    wire [3:0] b_valid_skewed;

    // Forwarding outputs use row-major PE indices: index = 4*row + column.
    // A PE reads A from index-1 (west) and B from index-4 (north).
    wire [7:0] a_forward [0:15];
    wire [7:0] b_forward [0:15];
    wire [15:0] a_valid_forward;
    wire [15:0] b_valid_forward;

    reg [5:0] drain_shift;
    // One drain bus per row: [3] is column 0 and [0] is column 3.
    wire [3:0] drain_rows [0:3];
    genvar lane;
    genvar row;
    genvar column;

    // Input skew: lane 0 is direct; lane n has n enabled-cycle delays.
    // Data and valid travel in the same shift register, so they cannot separate.
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_input_skew
            if (lane == 0) begin : g_direct
                assign a_skewed[lane] = a_in[7:0];
                assign b_skewed[lane] = b_in[7:0];
                assign a_valid_skewed[lane] = a_valid_in[0];
                assign b_valid_skewed[lane] = b_valid_in[0];
            end else begin : g_delay
                reg [9*lane-1:0] a_shift;
                reg [9*lane-1:0] b_shift;

                always @(posedge clk) begin
                    if (rst || clear) begin
                        a_shift <= {9*lane{1'b0}};
                        b_shift <= {9*lane{1'b0}};
                    end else if (en) begin
                        // Append the newest {valid,byte} at the low end.
                        // Assignment to the fixed register width drops the
                        // oldest entry; lane 1/2/3 stores 1/2/3 entries.
                        a_shift <= {a_shift, a_valid_in[lane],
                                    a_in[8*lane +: 8]};
                        b_shift <= {b_shift, b_valid_in[lane],
                                    b_in[8*lane +: 8]};
                    end
                end

                // The highest 9 bits contain the oldest delayed entry.
                assign {a_valid_skewed[lane], a_skewed[lane]} =
                    a_shift[9*lane-1 : 9*(lane-1)];
                assign {b_valid_skewed[lane], b_skewed[lane]} =
                    b_shift[9*lane-1 : 9*(lane-1)];
            end
        end
    endgenerate

    // Shared delay stages supply the travelling pulse for all four rows.
    // Bit 0 is a one-cycle delay; bit 5 is a six-cycle delay.
    always @(posedge clk) begin
        if (rst || clear)
            drain_shift <= 6'b0;
        else if (en)
            drain_shift <= {drain_shift[4:0], drain_in};
    end

    // For a single input pulse, the row buses follow this enabled-cycle order:
    //             row 0   row 1   row 2   row 3
    // offset 0:   1000    0000    0000    0000
    // offset 1:   0100    1000    0000    0000
    // offset 2:   0010    0100    1000    0000
    // offset 3:   0001    0010    0100    1000
    // offset 4:   0000    0001    0010    0100
    // offset 5:   0000    0000    0001    0010
    // offset 6:   0000    0000    0000    0001
    // Row 0 starts directly from drain_in, avoiding an extra delay at PE(0,0).
    // Rows share the same delay stages; no duplicate pulse registers are needed.
    // Gate the buses during stalls because the PE honors drain even with en=0.
    assign drain_rows[0] = {drain_in, drain_shift[0],
                           drain_shift[1], drain_shift[2]} & {4{en}};
    assign drain_rows[1] = {drain_shift[0], drain_shift[1],
                           drain_shift[2], drain_shift[3]} & {4{en}};
    assign drain_rows[2] = {drain_shift[1], drain_shift[2],
                           drain_shift[3], drain_shift[4]} & {4{en}};
    assign drain_rows[3] = {drain_shift[2], drain_shift[3],
                           drain_shift[4], drain_shift[5]} & {4{en}};

    // Fixed 4 x 4 mesh. Generate expands this single instance into 16 PEs.
    // Left/top edges use skewed source operands; other PEs use their neighbors.
    generate
        for (row = 0; row < 4; row = row + 1) begin : g_row
            for (column = 0; column < 4; column = column + 1) begin : g_column
                wire [7:0] a_operand;
                wire [7:0] b_operand;
                wire a_operand_valid;
                wire b_operand_valid;

                if (column == 0) begin : g_west_edge
                    assign a_operand = a_skewed[row];
                    assign a_operand_valid = a_valid_skewed[row];
                end else begin : g_west_neighbor
                    assign a_operand = a_forward[4*row+column-1];
                    assign a_operand_valid = a_valid_forward[4*row+column-1];
                end

                if (row == 0) begin : g_north_edge
                    assign b_operand = b_skewed[column];
                    assign b_operand_valid = b_valid_skewed[column];
                end else begin : g_north_neighbor
                    assign b_operand = b_forward[4*(row-1)+column];
                    assign b_operand_valid = b_valid_forward[4*(row-1)+column];
                end

                // Each packed byte is interpreted as signed by the PE ports.
                // The PE publishes the old sum while optionally starting the
                // next tile with the current product on the same drain edge.
                pe_booth_csa #(
                    .DATA_W(8),
                    .K_MAX(256),
                    .ACC_W(24)
                ) u_pe (
                    .clk(clk),
                    .rst(rst),
                    .en(en),
                    .clear(clear),
                    .drain(drain_rows[row][3-column]),
                    .a_in(a_operand),
                    .b_in(b_operand),
                    .a_valid_in(a_operand_valid),
                    .b_valid_in(b_operand_valid),
                    .a_out(a_forward[4*row+column]),
                    .b_out(b_forward[4*row+column]),
                    .a_valid_out(a_valid_forward[4*row+column]),
                    .b_valid_out(b_valid_forward[4*row+column]),
                    .result(results[24*(4*row+column) +: 24]),
                    .result_valid(results_valid[4*row+column])
                );
            end
        end
    endgenerate

endmodule

