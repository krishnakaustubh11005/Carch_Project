// Copies one row-major matrix from the data RAM into a scratchpad.
// The controller runs it once for A (rows=M, cols=K) and once for B
// (rows=K, cols=N), steering wr_* to scratchpad_a or scratchpad_b.
//
// RAM side: one word read per cycle on ram_en/ram_addr (word address).
//   ram_rdata must hold that word on the NEXT cycle (one-cycle BRAM latency).
// Scratchpad side: at most one write per cycle. Each write holds
//   M[wr_row][4*wr_word + 0..3], byte 0 in bits [7:0]; positions past the
//   end of the row are zero.
//
// Byte buffer (8 bytes): RAM words are appended in address order. The first
// word drops base_addr[1:0] leading bytes. A group of g = min(4, cols-col)
// bytes leaves from the front when the buffer holds g bytes. Bytes after the
// last element are left in the buffer and ignored.
//
// Look-ahead read rule: a word requested now arrives next cycle, after next
// cycle's group (if any) has left, so
//   ram_en = words left && (bytes_next - leaving_next + 4 <= 8).
// This never overflows and reads one word per cycle when cols % 4 == 0,
// whatever the alignment of base_addr.
//
// Control: start (ignored while busy) latches base_addr, rows and cols; the
// first RAM read follows two setup cycles later (see setup below).
// rows and cols must be 1..2**DIM_W. done pulses for one cycle after the last
// write, when busy falls. Synchronous rst abandons the copy.
module fetch_unit #(
    parameter DIM_W = 6,
    parameter RAM_ADDR_W = 10
) (
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [RAM_ADDR_W+1:0] base_addr,
    input  wire [DIM_W:0] rows,
    input  wire [DIM_W:0] cols,

    output wire ram_en,
    output wire [RAM_ADDR_W-1:0] ram_addr,
    input  wire [31:0] ram_rdata,

    output wire wr_en,
    output wire [DIM_W-1:0] wr_row,
    output wire [DIM_W-3:0] wr_word,
    output reg  [31:0] wr_data,

    output reg busy,
    output reg done
);
    localparam BYTE_W = RAM_ADDR_W + 2;

    // Job, latched on start.
    reg [DIM_W:0] rows_r, cols_r;
    reg [1:0] offset;

    // RAM address counter.
    reg [RAM_ADDR_W-1:0] next_word_addr;
    reg [RAM_ADDR_W:0] words_left;
    reg rdata_valid;     // a word requested last cycle is on ram_rdata now
    reg first_pending;   // the next arriving word is the first one

    // Byte buffer: byte 0 (bits [7:0]) is the oldest. Bytes at and above
    // `count` are always zero.
    reg [63:0] buffer;
    reg [3:0] count;

    // Write counters: next group starts at M[row][col], col a multiple of 4.
    reg [DIM_W:0] col, row;
    // Always cols_r - col. Kept in a register so this cycle's group size and
    // the look-ahead below need no subtraction from cols_r (timing).
    reg [DIM_W:0] remaining;

    // Word range of the matrix, worked out over two setup cycles after start
    // so that the multiply and the address arithmetic are in different
    // cycles (timing). RAM reads wait until setup reaches 0.
    //   setup 2: total_bytes <= rows_r * cols_r
    //   setup 1: words_left  <= last word - first word + 1
    reg [1:0] setup;
    reg [2*DIM_W+1:0] total_bytes;
    wire [BYTE_W-1:0] first_byte = {next_word_addr, offset};
    wire [BYTE_W-1:0] last_byte = first_byte + total_bytes - 1'b1;
    wire [RAM_ADDR_W:0] total_words =
        last_byte[BYTE_W-1:2] - next_word_addr + 1'b1;

    // This cycle's group.
    wire [2:0] g = (remaining >= 4) ? 3'd4 : remaining[2:0];
    wire emit = busy && (count >= g);
    wire row_end = emit && (remaining == {{(DIM_W-2){1'b0}}, g});
    wire last_group = row_end && (row + 1'b1 == rows_r);

    assign wr_en = emit;
    assign wr_row = row[DIM_W-1:0];
    assign wr_word = col[DIM_W-1:2];

    integer lane;
    always @* begin
        for (lane = 0; lane < 4; lane = lane + 1)
            wr_data[8*lane +: 8] = (lane < g) ? buffer[8*lane +: 8] : 8'd0;
    end

    // Buffer after the group leaves and the arriving word is appended.
    wire [3:0] count_e = count - (emit ? {1'b0, g} : 4'd0);
    wire [63:0] buffer_e = emit ? (buffer >> (8*g)) : buffer;
    wire [1:0] drop = first_pending ? offset : 2'd0;
    wire [31:0] incoming = rdata_valid ? (ram_rdata >> (8*drop)) : 32'd0;
    wire [2:0] bytes_in = rdata_valid ? (3'd4 - drop) : 3'd0;
    wire [95:0] merged = {32'd0, buffer_e} | ({64'd0, incoming} << (8*count_e));
    wire [3:0] count_n = count_e + bytes_in;

    // Write counters after this cycle.
    wire [DIM_W:0] col_n = !emit ? col : (row_end ? {(DIM_W+1){1'b0}} : col + g);
    wire [DIM_W:0] row_n = row_end ? row + 1'b1 : row;

    // Look-ahead: the group that will leave next cycle, before the new word lands.
    // remaining_n = cols_r - col_n, derived from the remaining register.
    wire [DIM_W:0] remaining_n = !emit ? remaining
                               : (row_end ? cols_r : remaining - {{(DIM_W-2){1'b0}}, g});
    wire [2:0] g_n = (remaining_n >= 4) ? 3'd4 : remaining_n[2:0];
    wire [4:0] leaves_n = (count_n >= g_n) ? {2'b00, g_n} : 5'd0;

    assign ram_en = busy && (setup == 2'd0) && !last_group && (words_left != 0)
                 && ({1'b0, count_n} + 5'd4 <= 5'd8 + leaves_n);
    assign ram_addr = next_word_addr;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            rdata_valid <= 1'b0;
            first_pending <= 1'b0;
            buffer <= 64'd0;
            count <= 4'd0;
            col <= 0;
            row <= 0;
            remaining <= 0;
            words_left <= 0;
            setup <= 2'd0;
        end else if (start && !busy) begin
            busy <= 1'b1;
            done <= 1'b0;
            rows_r <= rows;
            cols_r <= cols;
            offset <= base_addr[1:0];
            next_word_addr <= base_addr[BYTE_W-1:2];
            words_left <= 0;
            setup <= 2'd2;
            rdata_valid <= 1'b0;
            first_pending <= 1'b1;
            buffer <= 64'd0;
            count <= 4'd0;
            col <= 0;
            row <= 0;
            remaining <= cols;
        end else begin
            done <= 1'b0;
            if (busy && setup == 2'd2) begin
                total_bytes <= rows_r * cols_r;
                setup <= 2'd1;
            end else if (busy && setup == 2'd1) begin
                words_left <= total_words;
                setup <= 2'd0;
            end else if (busy) begin
                buffer <= merged[63:0];
                count <= count_n;
                col <= col_n;
                row <= row_n;
                remaining <= remaining_n;
                rdata_valid <= ram_en;
                if (rdata_valid)
                    first_pending <= 1'b0;
                if (ram_en) begin
                    next_word_addr <= next_word_addr + 1'b1;
                    words_left <= words_left - 1'b1;
                end
                if (last_group) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
