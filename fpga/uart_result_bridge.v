// Result port -> UART text. Each word written with valid=1 goes into a
// 64-word FIFO; the sender prints it as 8 upper-case hex digits plus "\r\n",
// 8N1, LSB first, CLKS_PER_BIT clocks per bit. overflow is sticky.
module uart_result_bridge #(
    parameter CLKS_PER_BIT = 50
) (
    input  wire clk,
    input  wire rst,                    // synchronous, active high
    input  wire valid,
    input  wire [31:0] word,
    output reg  tx,
    output reg  overflow
);
    // ---------------------------------------------------------------- FIFO
    reg [31:0] fifo [0:63];
    reg [6:0] wr_ptr, rd_ptr;
    wire empty = (wr_ptr == rd_ptr);
    wire full = (wr_ptr[5:0] == rd_ptr[5:0]) && (wr_ptr[6] != rd_ptr[6]);

    always @(posedge clk)
        if (valid && !full)
            fifo[wr_ptr[5:0]] <= word;

    // ---------------------------------------------------------------- sender
    reg [31:0] shift;                   // word being printed
    reg [3:0] char_idx;                 // 0-7 hex digits, 8 = CR, 9 = LF
    reg busy;                           // a word is being printed
    reg [9:0] frame;                    // stop, 8 data, start (LSB first)
    reg [3:0] bit_idx;                  // 0 = idle, else bits left
    reg [15:0] baud;

    function [7:0] hex;
        input [3:0] n;
        hex = (n < 10) ? 8'h30 + n : 8'h37 + n;
    endfunction

    wire [7:0] next_char = (char_idx < 8) ? hex(shift[31:28]) :
                           (char_idx == 8) ? 8'h0D : 8'h0A;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 7'd0;
            rd_ptr <= 7'd0;
            overflow <= 1'b0;
            busy <= 1'b0;
            bit_idx <= 4'd0;
            baud <= 16'd0;
            char_idx <= 4'd0;
            tx <= 1'b1;
        end else begin
            if (valid) begin
                if (full)
                    overflow <= 1'b1;
                else
                    wr_ptr <= wr_ptr + 7'd1;
            end

            if (bit_idx != 0) begin                 // shifting out one character
                if (baud == CLKS_PER_BIT - 1) begin
                    baud <= 16'd0;
                    tx <= frame[0];
                    frame <= {1'b1, frame[9:1]};
                    bit_idx <= bit_idx - 4'd1;
                end else
                    baud <= baud + 16'd1;
            end else if (busy) begin                // load the next character
                frame <= {1'b1, next_char, 1'b0};
                bit_idx <= 4'd11;          // 10 bits + one tick to finish the stop bit
                baud <= CLKS_PER_BIT - 1;           // first bit goes out next clock
                if (char_idx < 8)
                    shift <= {shift[27:0], 4'h0};
                if (char_idx == 9) begin
                    busy <= 1'b0;
                    char_idx <= 4'd0;
                end else
                    char_idx <= char_idx + 4'd1;
            end else if (!empty) begin              // take the next word
                shift <= fifo[rd_ptr[5:0]];
                rd_ptr <= rd_ptr + 7'd1;
                busy <= 1'b1;
            end
        end
    end
endmodule
