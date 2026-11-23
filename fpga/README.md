# Carch on the PYNQ-Z2

Full plan, troubleshooting and defense notes: PLAYBOOK.md (same as the
online "Carch: PYNQ-Z2 Demo Day Playbook" doc). Quick version:

Board: boot jumper JP1 on JTAG, power jumper on USB, micro-USB in PROG/UART, ON.
Shell: Vivado Tcl Shell (Windows) or `source <Vivado>/settings64.sh` (Linux),
then `cd` into this repo. Keep the repo path free of spaces.

    vivado -mode batch -source fpga/build.tcl                # 30-45 min; check "WNS" >= 0
    vivado -mode batch -source fpga/build.tcl -tclargs 40    # 25 MHz if WNS < 0
    vivado -mode batch -source fpga/hw.tcl                   # program; press BTN0 at ARMED
    vivado -mode batch -source fpga/hw.tcl -tclargs noprog   # capture again

LEDs: LD0 blink = clock, LD1 = PASS, LD2 = FAIL/trap/bus error, LD3 = UART overflow.

Interactive jobs (needs a bitstream from the current build.tcl, which adds a VIO).
In the Vivado Tcl Shell, after `cd` into the repo:

    source fpga/run.tcl
    run_program                          # once after power-up (or use hw.tcl)
    run_job 16 32 8 7                    # M K N seed: random int8 A, B
    run_matrix {1 2 3 4 -1 0 1 2 5 -3 2 0 0 1 -2 3} {1 0 2 -1 0 1 1 0 3 -2 0 1 1 1 -1 2}
    sweep {1 2 4 8 16 32 64}             # square jobs, summary table
    sweep_jobs {{64 64 4} {32 1 64} {4 64 4 9}}
    board_status                         # firmware runs, MMCM lock losses

Each job prints software vs accelerator cycles (bars, times, speed-up) and
PASS/FAIL, appends a row to fpga/out/results.csv and keeps the raw ILA data in
fpga/out/runs/. Chart: `python3 scripts/plot_results.py fpga/out/results.csv`
writes results.html. The firmware (fpga/fw/fpga_demo.c) reads the job from the
VIO through soc_top's cfg_in words at 0x8000_0004; `make fpga-run-sim` runs
the same flow in Icarus and checks it (scripts/check_fpga_run.py).

Baseline (CPU only): the same design with the accelerator removed
(soc_top ENABLE_ACCEL = 0), for its own utilization, timing and cycle counts.
Same firmware: it sees accelerator ID 0 and runs only the software matmul.

    vivado -mode batch -source fpga/build.tcl -tclargs baseline   # -> fpga/out_baseline/
    source scripts/report_summary.tcl; report_summary fpga/out_baseline
    source fpga/run.tcl
    run_program baseline                 # run_job / sweep as above; results in
    sweep {1 2 4 8 16 32 64}             #   fpga/out_baseline/results.csv
    run_program                          # back to the accelerator build

`make fpga-baseline-sim` runs the fpga-run-sim jobs on the baseline in Icarus.

No board: `build.tcl -tclargs 20 sim`, then `sim.tcl -tclargs func` or
`timing` (add `gui` for waves). No Vivado: `make fpga-rtl-sim` (power-up job
over the UART) or `make fpga-run-sim` (several VIO jobs).

Firmware source fpga/fw/fpga_demo.c; `make fpga-fw` rebuilds the committed .hex.
Pins in pynq_z2.xdc are from memory: check against the PYNQ-Z2 master XDC.
