# Run a user program on the PYNQ-Z2 (fpga/user/README.md); started by
# carch_user.py, which has already put the program into each bitstream with
# updatemem.
#   vivado -mode batch -source fpga/user/board.tcl -tclargs \
#       <name> <bit> <ltx> <csv>  [<name> <bit> <ltx> <csv> ...]
# For each bitstream: program it, arm the ILA on dbg_valid, pulse the VIO
# soft reset (the program reruns from the start), wait for the report burst
# and save the ILA samples as CSV. Errors print a CARCH_ERROR line.
# The board must not be held by another Vivado (close the GUI's hardware target).

proc fail {msg} {
    puts "CARCH_ERROR: $msg"
    exit 1
}

proc probe_of {obj patterns} {
    foreach p [get_hw_probes -of_objects $obj] {
        foreach pat $patterns {
            if {[string match "*$pat*" [get_property NAME $p]]} { return $p }
        }
    }
    fail "probe [lindex $patterns 0] not found on $obj"
}

if {[llength $argv] % 4 != 0 || [llength $argv] == 0} {
    fail "usage: -tclargs <name> <bit> <ltx> <csv> ..."
}

open_hw_manager
if {[catch {connect_hw_server} err]} { fail "cannot start or reach hw_server: $err" }
if {[catch {open_hw_target} err]} {
    fail "no board on the JTAG cable (is it on? is another Vivado holding it?): $err"
}
set dev [lindex [get_hw_devices xc7z020*] 0]
if {$dev eq ""} { fail "no xc7z020 on the JTAG chain" }
current_hw_device $dev

foreach {name bit ltx csv} $argv {
    puts "==== $name: programming [file tail $bit] ===="
    set_property PROBES.FILE $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
    set_property PROGRAM.FILE $bit $dev
    if {[catch {program_hw_devices $dev} err]} { fail "programming failed: $err" }
    refresh_hw_device $dev

    set ila [lindex [get_hw_ilas -of_objects $dev] 0]
    set vio [lindex [get_hw_vios -of_objects $dev] 0]
    if {$ila eq "" || $vio eq ""} { fail "bitstream has no ILA/VIO (rebuild with fpga/build.tcl)" }
    set rst [probe_of $vio {vio_rst probe_out4}]
    set_property CONTROL.DATA_DEPTH 4096 $ila
    set_property CONTROL.TRIGGER_POSITION 8 $ila
    catch {set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila}
    set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes dbg_valid -of_objects $ila]

    # The program already ran once after configuration (unrecorded); run it
    # again with the ILA armed.
    run_hw_ila $ila
    set_property OUTPUT_VALUE 1 $rst
    commit_hw_vio $rst
    set_property OUTPUT_VALUE 0 $rst
    commit_hw_vio $rst
    if {[catch {wait_on_hw_ila -timeout 2 $ila} err]} {
        fail "$name: no result within 2 minutes ($err): program too long, or it crashed"
    }
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file $csv $data
    puts "==== $name: captured -> $csv ===="
}
catch {close_hw_target}
catch {disconnect_hw_server}
puts "CARCH_OK"
