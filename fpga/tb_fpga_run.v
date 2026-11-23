`timescale 1ns/1ps
// Several VIO-configured jobs on fpga_top, as fpga/run.tcl drives the board
// (make fpga-run-sim). Uses the vio_cfg stand-in (fpga/sim_stubs/vio_cfg.v):
// sets the job, pulses the soft reset, and logs every result word the ILA
// would record (dbg_valid / dbg_result) as
//   W <job> <clock> <hex>
// Job 0 is the power-up job (no soft reset). scripts/check_fpga_run.py decodes
// the log, checks C = A x B and PASS/FAIL, and checks each report burst fits
// one ILA window.
module tb_fpga_run #(parameter [0:0] ENABLE_ACCEL = 1);   // 0: baseline (make fpga-baseline-sim)
    reg clk125 = 1'b0;
    wire [3:0] led;
    wire uart_tx;
    always #4 clk125 = !clk125;

    fpga_top #(.ENABLE_ACCEL(ENABLE_ACCEL)) dut (.clk125(clk125), .btn0(1'b0), .led(led), .uart_tx(uart_tx));

    integer clocks = 0, job = 0, finals = 0;
    always @(posedge dut.clk) clocks <= clocks + 1;

    // Frame tracking: a word outside a matrix or benchmark frame is the final
    // result word of the job.
    integer state = 0, left = 0;
    reg [31:0] rows_r, mode;
    always @(posedge dut.clk) if (dut.dbg_valid) begin
        $display("W %0d %0d %08h", job, clocks, dut.dbg_result);
        case (state)
            0: if (dut.dbg_result[31:8] == 24'hCA0000) begin
                   mode = dut.dbg_result[7:0]; state = 1;
               end else if (dut.dbg_result[31:24] == 8'hD0) begin
                   left = dut.dbg_result[7:0]; state = 3;
               end else
                   finals = finals + 1;
            1: begin rows_r = dut.dbg_result; state = 2; end
            2: begin
                   left = (mode == 8'hC4) ? rows_r * dut.dbg_result : (rows_r * dut.dbg_result + 3) / 4;
                   state = (left > 0) ? 3 : 0;
               end
            3: begin left = left - 1; if (left == 0) state = 0; end
        endcase
    end

    task run_job(input [31:0] ctrl, input [31:0] seed, input [127:0] a, input [127:0] b);
        integer start;
        begin
            @(posedge dut.clk);
            job = job + 1;
            $display("J %0d ctrl=%08h seed=%08h a=%032h b=%032h", job, ctrl, seed, a, b);
            start = finals;
            dut.u_vio.probe_out0 = ctrl;
            dut.u_vio.probe_out1 = seed;
            dut.u_vio.probe_out2 = a;
            dut.u_vio.probe_out3 = b;
            repeat (4) @(posedge dut.clk);
            dut.u_vio.probe_out4 = 1'b1;
            repeat (3) @(posedge dut.clk);
            dut.u_vio.probe_out4 = 1'b0;
            wait (finals == start + 1);
            repeat (10) @(posedge dut.clk);
            $display("M %0d runs=%0d unlocks=%0d words=%0d", job, dut.mon_runs, dut.mon_unlocks, dut.mon_words);
        end
    endtask

    function [31:0] ctrl_word(input [6:0] m, input [6:0] k, input [6:0] n, input mat);
        ctrl_word = {10'd0, mat, n, k, m};
    endfunction

    initial begin
        $display("J 0 power-up");
        wait (finals == 1);
        repeat (10) @(posedge dut.clk);
        $display("M 0 runs=%0d unlocks=%0d words=%0d", dut.mon_runs, dut.mon_unlocks, dut.mon_words);
        run_job(ctrl_word(3, 5, 2, 0), 32'd7, 0, 0);
        run_job(ctrl_word(8, 8, 8, 0), 32'd12345, 0, 0);
        run_job(ctrl_word(1, 1, 1, 0), 32'd3, 0, 0);
        // 2x3 x 3x2, own values: A = [1 -2 3; 4 5 -6], B = [7 8; -9 10; 11 -12]
        run_job(ctrl_word(2, 3, 2, 1), 32'd0,
                {80'd0, 8'hFA, 8'h05, 8'h04, 8'h03, 8'hFE, 8'h01},
                {80'd0, 8'hF4, 8'h0B, 8'h0A, 8'hF7, 8'h08, 8'h07});
        run_job(ctrl_word(16, 9, 5, 0), 32'd99, 0, 0);
        run_job(ctrl_word(4, 4, 4, 0), 32'd0, 0, 0);              // seed 0 -> 1
        run_job(ctrl_word(0, 4, 4, 0), 32'd1, 0, 0);              // bad M -> FAIL test 4
        run_job(ctrl_word(5, 4, 4, 1), 32'd1, 0, 0);              // matrix mode, 20 values -> FAIL
        run_job(ctrl_word(64, 64, 1, 0), 32'd5, 0, 0);           // largest M and K
        $display("DONE");
        $finish;
    end

    initial begin
        #(200_000_000);
        $display("TIMEOUT job %0d", job);
        $finish;
    end
endmodule
