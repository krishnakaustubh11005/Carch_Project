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

No board: `build.tcl -tclargs 20 sim`, then `sim.tcl -tclargs func` or
`timing` (add `gui` for waves). No Vivado: `make fpga-rtl-sim`.

Firmware source fpga/fw/fpga_demo.c; `make fpga-fw` rebuilds the committed .hex.
Pins in pynq_z2.xdc are from memory: check against the PYNQ-Z2 master XDC.
