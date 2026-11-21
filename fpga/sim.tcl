# Simulate fpga_top with Vivado's simulator (fpga/README.md).
#   vivado -mode batch -source fpga/sim.tcl -tclargs rtl      your Verilog
#   vivado -mode batch -source fpga/sim.tcl -tclargs func     post-route netlist, no delays
#   vivado -mode batch -source fpga/sim.tcl -tclargs timing   post-route netlist + SDF delays
# Add "gui" after the mode to open the waveform viewer instead.
# func and timing need fpga/build.tcl to have run first.
set here [file normalize [file dirname [info script]]]
set root [file dirname $here]
set out  $here/out
set mode [lindex $argv 0]
set gui  [expr {[lsearch $argv gui] >= 0}]
set viv  $::env(XILINX_VIVADO)
set ext  [expr {$::tcl_platform(platform) eq "windows" ? ".bat" : ""}]
set tb   $here/tb_fpga_top.v
set glbl $viv/data/verilog/src/glbl.v

proc tool {name args} {
    global viv ext
    puts ">> $name [join $args]"
    exec $viv/bin/$name$ext {*}$args >@ stdout 2>@ stderr
}

set run $out/sim_$mode
file mkdir $run
cd $run

switch -- $mode {
    rtl {
        set f [open $out/fw_path.vh w]
        puts $f "`define FPGA_FIRMWARE \"$here/fw/fpga_demo.hex\""
        close $f
        tool xvlog -i $out {*}[glob $root/rtl/*.v] $here/fpga_top.v $here/uart_result_bridge.v $tb $glbl
        set elab [list -L unisims_ver -L secureip]
    }
    func {
        tool xvlog $out/fpga_top_funcsim.v $tb $glbl
        set elab [list -L unisims_ver -L secureip]
    }
    timing {
        tool xvlog $out/fpga_top_timesim.v $tb $glbl
        set elab [list -L simprims_ver -L secureip -maxdelay -transport_int_delays \
                      -pulse_r 0 -pulse_int_r 0 \
                      -sdfmax /tb_fpga_top/dut=$out/fpga_top_timesim.sdf]
    }
    default {
        error "usage: -tclargs rtl|func|timing \[gui\]"
    }
}

tool xelab -debug typical {*}$elab -s snap work.tb_fpga_top work.glbl

if {$gui} {
    set f [open wave.tcl w]
    puts $f "log_wave -recursive *"
    puts $f "add_wave /tb_fpga_top/clk125 /tb_fpga_top/btn0 /tb_fpga_top/led /tb_fpga_top/uart_tx"
    puts $f "add_wave /tb_fpga_top/tag /tb_fpga_top/w"
    puts $f "run all"
    close $f
    tool xsim snap -gui -tclbatch wave.tcl
} else {
    set f [open run.tcl w]
    puts $f "run all"
    puts $f "quit"
    close $f
    tool xsim snap -tclbatch run.tcl
}
puts "==== log: $run/xsim.log ===="
