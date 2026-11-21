// Copies the M x N result from c_store to the data RAM, row-major, one word
// per cycle. C is contiguous in RAM, so the RAM word address starts at
// c_word_addr and simply increments; rows >= M and columns >= N of c_store
// (tile padding) are never read.
//
// c_store side: rd_row/rd_col are read on rd_en; rd_data holds the word on
// the NEXT cycle (one-cycle RAM latency) and goes straight to ram_wdata.
// RAM side: at most one full-word write per cycle (ram_we = 4'b1111 with
// ram_en). The copier never reads the RAM.
//
// rows_ready: row r is read only when r < rows_ready. v1 holds it at M, so
// the copy never pauses; a later version can raise it row group by row
// group while compute is still running.
//
// Control: start (ignored while busy) latches c_word_addr, m and n, which
// must be 1..2**DIM_W. busy covers M*N + 1 cycles; done pulses for one cycle
// after the last write, when busy falls. Synchronous rst abandons the copy.
module c_copier #(
    parameter DIM_W = 6,
    parameter RAM_ADDR_W = 10
) (
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [RAM_ADDR_W-1:0] c_word_addr,
    input  wire [DIM_W:0] m,
    input  wire [DIM_W:0] n,
    input  wire [DIM_W:0] rows_ready,

    output wire rd_en,
    output wire [DIM_W-1:0] rd_row,
    output wire [DIM_W-1:0] rd_col,
    input  wire [31:0] rd_data,

    output wire ram_en,
    output wire [3:0] ram_we,
    output wire [RAM_ADDR_W-1:0] ram_addr,
    output wire [31:0] ram_wdata,

    output reg busy,
    output reg done
);
    // Job, latched on start.
    reg [DIM_W:0] m_r, n_r;

    // Read side: next C element to read from c_store.
    reg [DIM_W:0] row, col;
    // Write side: a read was issued last cycle, so rd_data must be written now.
    reg wr_pending;
    reg [RAM_ADDR_W-1:0] wr_addr;

    wire can_read = busy && (row != m_r) && (row < rows_ready);
    wire row_end = (col + 1'b1 == n_r);
    // After the last read, row == m_r and the final write is pending.
    wire finish = busy && (row == m_r);

    assign rd_en = can_read;
    assign rd_row = row[DIM_W-1:0];
    assign rd_col = col[DIM_W-1:0];

    assign ram_en = wr_pending;
    assign ram_we = {4{wr_pending}};
    assign ram_addr = wr_addr;
    assign ram_wdata = rd_data;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            wr_pending <= 1'b0;
            row <= 0;
            col <= 0;
        end else if (start && !busy) begin
            busy <= 1'b1;
            done <= 1'b0;
            m_r <= m;
            n_r <= n;
            row <= 0;
            col <= 0;
            wr_pending <= 1'b0;
            wr_addr <= c_word_addr;
        end else begin
            done <= 1'b0;
            if (busy) begin
                wr_pending <= can_read;
                if (can_read) begin
                    if (row_end) begin
                        col <= 0;
                        row <= row + 1'b1;
                    end else begin
                        col <= col + 1'b1;
                    end
                end
                if (wr_pending)
                    wr_addr <= wr_addr + 1'b1;
                if (finish) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
