# Vivado non-project build of fpga_top for the PYNQ-Z2 (fpga/README.md).
#   vivado -mode batch -source fpga/build.tcl                   board build, 50 MHz, with ILA
#   vivado -mode batch -source fpga/build.tcl -tclargs 40       same at 25 MHz (if timing fails)
#   vivado -mode batch -source fpga/build.tcl -tclargs 20 sim   no ILA; also writes the post-route
#                                                               netlists for sim.tcl func / timing
# Outputs in fpga/out/: fpga_top.bit, fpga_top.ltx (ILA probes), *.rpt.
set here [file normalize [file dirname [info script]]]
set root [file dirname $here]
set out  $here/out
set part xc7z020clg400-1
set clk_div [expr {$argc > 0 ? [lindex $argv 0] : 20}]
set sim     [expr {[lsearch $argv sim] >= 0}]
file mkdir $out

set f [open $out/fw_path.vh w]
puts $f "`define FPGA_FIRMWARE \"$here/fw/fpga_demo.hex\""
close $f

puts "==== Carch on $part, clock = [expr {1000 / $clk_div}] MHz, ILA = [expr {$sim ? "no" : "yes"}] ===="
read_verilog [glob $root/rtl/*.v]
read_verilog [list $here/fpga_top.v $here/uart_result_bridge.v]
read_xdc $here/pynq_z2.xdc

synth_design -top fpga_top -part $part -include_dirs $out -generic CLK_DIV=$clk_div
report_utilization -file $out/utilization_synth.rpt

if {!$sim} {
    # ILA: 2048 samples of {dbg_result, dbg_valid} at the system clock. The
    # demo's 42 result words span about 660 clocks, so one trigger catches all.
    create_debug_core u_ila_0 ila
    set_property C_DATA_DEPTH 2048 [get_debug_cores u_ila_0]
    set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
    set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
    set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
    set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
    set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
    set_property port_width 1 [get_debug_ports u_ila_0/clk]
    connect_debug_port u_ila_0/clk [get_nets clk]
    set nets {}
    for {set i 0} {$i < 32} {incr i} { lappend nets [get_nets "dbg_result\[$i\]"] }
    set_property port_width 32 [get_debug_ports u_ila_0/probe0]
    connect_debug_port u_ila_0/probe0 $nets
    create_debug_port u_ila_0 probe
    set_property port_width 1 [get_debug_ports u_ila_0/probe1]
    connect_debug_port u_ila_0/probe1 [get_nets dbg_valid]
    set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
    set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
    set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
    connect_debug_port dbg_hub/clk [get_nets clk]
}
write_checkpoint -force $out/post_synth.dcp

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp

report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
report_timing_summary -max_paths 10 -file $out/timing_summary.rpt
report_power -file $out/power.rpt
report_drc -file $out/drc.rpt

if {$sim} {
    write_verilog -mode funcsim -force $out/fpga_top_funcsim.v
    write_verilog -mode timesim -sdf_anno false -force $out/fpga_top_timesim.v
    write_sdf -force $out/fpga_top_timesim.sdf
} else {
    write_debug_probes -force $out/fpga_top.ltx
}

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "==== timing: WNS = $wns ns (setup), WHS = $whs ns (hold) ===="
if {$wns < 0 || $whs < 0} {
    puts "==== TIMING FAILED: rerun with -tclargs 40 (25 MHz) ===="
}

if {[catch {write_bitstream -force $out/fpga_top.bit} err]} {
    puts "==== bitstream not written: $err ===="
} else {
    puts "==== wrote $out/fpga_top.bit ===="
}
puts "==== reports in $out: utilization.rpt timing_summary.rpt power.rpt ===="
