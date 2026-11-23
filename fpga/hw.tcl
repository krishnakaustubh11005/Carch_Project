# Program the PYNQ-Z2 and read the demo's results back through the ILA
# (fpga/README.md). Board: boot jumper on JTAG, powered, USB cable in.
#   vivado -mode batch -source fpga/hw.tcl            program + capture + print
#   vivado -mode batch -source fpga/hw.tcl -tclargs noprog   capture again only
# When it says ARMED, press BTN0 (reset): the firmware reruns and the ILA
# records every word written to the result port. Writes fpga/out/capture.csv
# and prints A, B, C, the cycle counts and PASS/FAIL.
set here [file normalize [file dirname [info script]]]
set out  $here/out
set prog [expr {[lsearch $argv noprog] < 0}]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
current_hw_device $dev
set_property PROBES.FILE $out/fpga_top.ltx $dev
set_property FULL_PROBES.FILE $out/fpga_top.ltx $dev
if {$prog} {
    set_property PROGRAM.FILE $out/fpga_top.bit $dev
    program_hw_devices $dev
    puts "==== programmed $dev (DONE LED should be on, LD0 blinking) ===="
}
refresh_hw_device $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 8 $ila
# Read-only (and already BASIC_ONLY) when the ILA has no advanced trigger.
catch {set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila}
set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes dbg_valid -of_objects $ila]
run_hw_ila $ila
puts ""
puts "==== ARMED: press BTN0 on the board now (waiting up to 2 minutes) ===="
puts ""
wait_on_hw_ila -timeout 2 $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $out/capture.csv $data
puts "==== captured -> $out/capture.csv ===="

# ------------------------------------------------------------ decode
# CSV: header row with probe names, a radix row, then one row per sample.
set fh [open $out/capture.csv]
set lines [split [read $fh] "\n"]
close $fh
set head [split [lindex $lines 0] ","]
set ci_r -1; set ci_v -1
for {set i 0} {$i < [llength $head]} {incr i} {
    set name [lindex $head $i]
    if {[string match *dbg_result* $name]} { set ci_r $i }
    if {[string match *dbg_valid* $name]}  { set ci_v $i }
}
set words {}
foreach line [lrange $lines 1 end] {
    set cols [split $line ","]
    if {![string is integer -strict [lindex $cols 0]]} continue
    # scan %x gives a signed 32-bit value (0xCA0000A1 < 0); mask it back to unsigned.
    if {[scan [lindex $cols $ci_v] %x] == 1} { lappend words [expr {[scan [lindex $cols $ci_r] %x] & 0xFFFFFFFF}] }
}
puts "==== [llength $words] result words ===="

proc s32 {x} { expr {$x >= 0x80000000 ? $x - 0x100000000 : $x} }
proc s8  {x} { expr {$x >= 0x80 ? $x - 0x100 : $x} }
set i 0
while {$i < [llength $words]} {
    set tag [lindex $words $i]; incr i
    if {($tag >> 8) == 0xCA0000} {
        set rows [lindex $words $i]; set cols [lindex $words [expr {$i + 1}]]; incr i 2
        set kind [expr {$tag & 0xFF}]
        set name [dict get {161 A 177 B 196 {C = A x B}} $kind]
        puts "\nmatrix $name  ($rows x $cols)"
        set vals {}
        if {$kind == 0xC4} {
            for {set n 0} {$n < $rows * $cols} {incr n} { lappend vals [s32 [lindex $words $i]]; incr i }
        } else {
            set nw [expr {($rows * $cols + 3) / 4}]
            for {set n 0} {$n < $nw} {incr n} {
                set w [lindex $words $i]; incr i
                for {set b 0} {$b < 4} {incr b} { lappend vals [s8 [expr {($w >> (8 * $b)) & 0xFF}]] }
            }
        }
        for {set r 0} {$r < $rows} {incr r} {
            set row {}
            for {set c 0} {$c < $cols} {incr c} { append row [format " %6d" [lindex $vals [expr {$r * $cols + $c}]]] }
            puts "    \[$row \]"
        }
    } elseif {($tag >> 24) == 0xD0} {
        set count [expr {$tag & 0xFF}]
        lassign [lrange $words $i [expr {$i + $count - 1}]] m k n sw acc fetch comp instr
        incr i $count
        puts "\nbenchmark  ${m}x${k}x${n}"
        puts "    software (CPU only) : $sw cycles"
        puts "    accelerator         : $acc cycles  (fetch $fetch, compute $comp)"
        if {$instr ne ""} {
            puts [format "    CPU                 : %d instructions, CPI %.2f" $instr [expr {double($sw) / $instr}]]
        }
        if {$acc} { puts [format "    speed-up            : %.1fx" [expr {double($sw) / $acc}]] }
    } else {
        puts [format "\nfinal result word 0x%08X -> %s" $tag [expr {$tag == 1 ? "PASS" : "FAIL"}]]
    }
}
