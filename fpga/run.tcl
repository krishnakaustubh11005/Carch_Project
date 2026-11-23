# Interactive Carch jobs on the PYNQ-Z2 (fpga/README.md).
# Needs a bitstream built by fpga/build.tcl with the VIO (from 2026-11-22 on).
#
# In the Vivado Tcl Shell, from the repo folder:
#   source fpga/run.tcl
#   run_program                      program the board (only after power-up)
#   run_program baseline             program the CPU-only baseline build instead
#                                    (fpga/out_baseline; switch back with run_program)
#   run_job 16 32 8                  M K N, pseudo-random int8 A and B, seed 1
#   run_job 16 32 8 7                ... seed 7
#   run_matrix {1 2 3 4 -1 0 1 2 5 -3 2 0 0 1 -2 3} {1 0 2 -1 0 1 1 0 3 -2 0 1 1 1 -1 2}
#                                    your own values, 4x4x4 (row-major)
#   run_matrix {1 -2 3 4 5 -6} {7 8 -9 10 11 -12} 2 3 2
#                                    your own values, M K N given (M*K, K*N <= 16)
#   sweep {1 2 4 8 16 32 64}         square jobs, seed 1   (sweep {...} 7 for seed 7)
#   sweep_jobs {{64 64 4} {32 1 64} {4 64 4 9}}   any list of {M K N ?seed?}
#   board_status                     firmware runs, MMCM lock losses, words, last result
#
# Each job: the laptop writes the job into the FPGA through the VIO, arms the
# ILA, pulses the VIO soft reset (no BTN0 needed), and the firmware runs the
# accelerator job and the same matmul in software, checks every C value and
# reports. Results: printed, appended to fpga/out/results.csv, raw ILA data in
# fpga/out/runs/. Chart: python3 scripts/plot_results.py fpga/out/results.csv
# Times assume a 50 MHz clock; after building with -tclargs 40 run
#   set carch(mhz) 25

set carch(here) [file normalize [file dirname [info script]]]
if {![info exists carch(out)]} { set carch(out) $carch(here)/out }
if {![info exists carch(mhz)]} { set carch(mhz) 50 }
if {![info exists carch(job)]} { set carch(job) 0 }

# ---------------------------------------------------------------- connection
# current_hw_server / current_hw_target only warn (no error) when nothing is
# open, so test for an empty answer as well as an error.
proc carch_none {cmd} {
    expr {[catch {uplevel #0 $cmd} r] || $r eq ""}
}

proc carch_open_target {} {
    if {[carch_none current_hw_target]} {
        catch {open_hw_manager}
        if {[carch_none current_hw_server]} { connect_hw_server }
        open_hw_target
    }
    set dev [lindex [get_hw_devices xc7z020*] 0]
    if {$dev eq ""} {
        error "no xc7z020 found on the JTAG cable: is the board on, JP1 on JTAG, USB in PROG/UART?"
    }
    current_hw_device $dev
    set_property PROBES.FILE $::carch(out)/fpga_top.ltx $dev
    set_property FULL_PROBES.FILE $::carch(out)/fpga_top.ltx $dev
    return $dev
}

# Which build the board runs: accel (fpga/out) or baseline (fpga/out_baseline).
# Bitstream, probes, run captures and results.csv all live in that folder.
proc run_use {which} {
    global carch
    switch -- $which {
        accel    { set carch(out) $carch(here)/out }
        baseline { set carch(out) $carch(here)/out_baseline }
        default  { error "run_use accel|baseline" }
    }
    catch {unset carch(vio)}
    puts "==== using $which build: $carch(out) ===="
}

proc run_program {{which accel}} {
    global carch
    run_use $which
    if {![file exists $carch(out)/fpga_top.bit]} {
        error "$carch(out)/fpga_top.bit missing: build it first (build.tcl[expr {$which eq "baseline" ? " -tclargs baseline" : ""}])"
    }
    set dev [carch_open_target]
    set_property PROGRAM.FILE $carch(out)/fpga_top.bit $dev
    program_hw_devices $dev
    puts "==== programmed $dev ($which): LD0 blinks, LD1 = PASS of the power-up 4x4x4 job ===="
    catch {unset carch(vio)}
    carch_connect
}

proc carch_probe {patterns} {
    foreach p [get_hw_probes -of_objects $::carch(vio)] {
        foreach pat $patterns {
            if {[string match "*$pat*" [get_property NAME $p]]} { return $p }
        }
    }
    error "VIO probe [lindex $patterns 0] not found. VIO probes: [get_hw_probes -of_objects $::carch(vio)]"
}

proc carch_connect {} {
    global carch
    if {[info exists carch(vio)]} { return }
    set carch(dev) [carch_open_target]
    refresh_hw_device $carch(dev)
    set carch(ila) [lindex [get_hw_ilas -of_objects $carch(dev)] 0]
    set carch(vio) [lindex [get_hw_vios -of_objects $carch(dev)] 0]
    if {$carch(vio) eq ""} {
        unset carch(vio)
        error "the FPGA has no VIO: build with the current fpga/build.tcl, then run_program"
    }
    foreach {key patterns} {
        ctrl {vio_ctrl probe_out0}  seed {vio_seed probe_out1}  a {vio_a probe_out2}
        b {vio_b probe_out3}  rst {vio_rst probe_out4}
        result {mon_result probe_in0}  words {mon_words probe_in1}
        runs {mon_runs probe_in2}  unlocks {mon_unlocks probe_in3}
    } {
        set carch(p,$key) [carch_probe $patterns]
    }
    foreach key {ctrl seed a b rst} { set_property OUTPUT_VALUE_RADIX HEX $carch(p,$key) }
    foreach key {result} { set_property INPUT_VALUE_RADIX HEX $carch(p,$key) }
    foreach key {words runs unlocks} { set_property INPUT_VALUE_RADIX UNSIGNED $carch(p,$key) }
    set ila $carch(ila)
    set_property CONTROL.DATA_DEPTH 4096 $ila
    set_property CONTROL.TRIGGER_POSITION 8 $ila
    catch {set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila}
    set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes dbg_valid -of_objects $ila]
    puts "==== connected: [get_property NAME $carch(dev)], ILA + VIO ready ===="
}

# ---------------------------------------------------------------- VIO access
proc carch_set {key hex} {
    set p $::carch(p,$key)
    set_property OUTPUT_VALUE $hex $p
    commit_hw_vio $p
}

proc carch_counters {} {
    global carch
    refresh_hw_vio $carch(vio)
    set c {}
    foreach key {runs unlocks words} { dict set c $key [get_property INPUT_VALUE $carch(p,$key)] }
    dict set c result [get_property INPUT_VALUE $carch(p,result)]
    return $c
}

proc board_status {} {
    carch_connect
    set c [carch_counters]
    puts "firmware runs since programming : [dict get $c runs]"
    puts "MMCM lock losses                : [dict get $c unlocks]"
    puts "result words in the last run    : [dict get $c words]"
    puts "last result word                : 0x[dict get $c result]"
}

# 16 int8 values -> 128-bit hex, element 0 in the low byte.
proc carch_pack {values} {
    set hex ""
    for {set i 15} {$i >= 0} {incr i -1} {
        set v [expr {$i < [llength $values] ? [lindex $values $i] : 0}]
        append hex [format %02X [expr {$v & 0xFF}]]
    }
    return $hex
}

# ---------------------------------------------------------------- capture and decode
proc carch_words {csv} {
    set fh [open $csv]
    set lines [split [read $fh] "\n"]
    close $fh
    set head [split [lindex $lines 0] ","]
    set ci_r -1; set ci_v -1
    for {set i 0} {$i < [llength $head]} {incr i} {
        if {[string match *dbg_result* [lindex $head $i]]} { set ci_r $i }
        if {[string match *dbg_valid* [lindex $head $i]]}  { set ci_v $i }
    }
    set words {}
    foreach line [lrange $lines 1 end] {
        set cols [split $line ","]
        if {![string is integer -strict [lindex $cols 0]]} continue
        # scan %x gives a signed 32-bit value; mask it back to unsigned.
        if {[scan [lindex $cols $ci_v] %x] == 1} {
            lappend words [expr {[scan [lindex $cols $ci_r] %x] & 0xFFFFFFFF}]
        }
    }
    return $words
}

proc carch_s8  {x} { expr {$x >= 0x80 ? $x - 0x100 : $x} }
proc carch_s32 {x} { expr {$x >= 0x80000000 ? $x - 0x100000000 : $x} }

# Words -> dict: A/B/C {rows cols values}, bench {m k n sw accel fetch compute}, final.
proc carch_decode {words} {
    set r [dict create]
    set i 0
    while {$i < [llength $words]} {
        set tag [lindex $words $i]; incr i
        if {($tag >> 8) == 0xCA0000} {
            set rows [lindex $words $i]; set cols [lindex $words [expr {$i + 1}]]; incr i 2
            set kind [expr {$tag & 0xFF}]
            set vals {}
            if {$kind == 0xC4} {
                for {set n 0} {$n < $rows * $cols} {incr n} {
                    lappend vals [carch_s32 [lindex $words $i]]; incr i
                }
                set name C
            } else {
                set nw [expr {($rows * $cols + 3) / 4}]
                for {set n 0} {$n < $nw} {incr n} {
                    set w [lindex $words $i]; incr i
                    for {set b 0} {$b < 4} {incr b} {
                        lappend vals [carch_s8 [expr {($w >> (8 * $b)) & 0xFF}]]
                    }
                }
                set vals [lrange $vals 0 [expr {$rows * $cols - 1}]]
                set name [expr {$kind == 0xA1 ? "A" : "B"}]
            }
            dict set r $name [list $rows $cols $vals]
        } elseif {($tag >> 24) == 0xD0} {
            dict set r bench [lrange $words $i [expr {$i + 6}]]
            incr i 7
        } else {
            dict set r final $tag
        }
    }
    return $r
}

proc carch_print_matrix {name m} {
    lassign $m rows cols vals
    puts "  $name  ($rows x $cols)"
    for {set r 0} {$r < $rows} {incr r} {
        set row ""
        for {set c 0} {$c < $cols} {incr c} {
            append row [format " %7d" [lindex $vals [expr {$r * $cols + $c}]]]
        }
        puts "    \[$row \]"
    }
}

proc carch_verdict {final} {
    if {$final == 1} { return PASS }
    set t [expr {($final >> 16) & 0xFFF}]
    set why [dict get {1 "accelerator ID wrong" 2 "START rejected" 3 "C mismatch"
                       4 "bad job configuration"} $t]
    return [format "FAIL 0x%08X (%s)" $final $why]
}

# Runs the configured job once; returns the decoded dict plus a summary row.
proc carch_run {label m k n data seed} {
    global carch
    set before [carch_counters]
    set ila $carch(ila)
    run_hw_ila $ila
    carch_set rst 1
    carch_set rst 0
    if {[catch {wait_on_hw_ila -timeout 1 $ila} err]} {
        error "no result from the board within 1 minute ($err). Check LD0 blinks; try board_status."
    }
    set data_obj [upload_hw_ila_data $ila]
    incr carch(job)
    file mkdir $carch(out)/runs
    set csv $carch(out)/runs/job_$carch(job).csv
    write_hw_ila_data -force -csv_file $csv $data_obj
    set r [carch_decode [carch_words $csv]]
    set after [carch_counters]

    puts ""
    puts "==== job $carch(job): ${m}x${k}x${n}, $label ===="
    foreach name {A B C} {
        if {[dict exists $r $name]} { carch_print_matrix $name [dict get $r $name] }
    }
    if {![dict exists $r final]} { error "incomplete capture: see $csv" }
    set verdict [carch_verdict [dict get $r final]]
    if {[dict exists $r bench] && [lindex [dict get $r bench] 4] == 0 && $verdict eq "PASS"} {
        set verdict "PASS (baseline)"
    }
    set row [list $carch(job) [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] \
                 $m $k $n $data $seed {} {} {} {} {} $verdict]
    if {[dict exists $r bench]} {
        lassign [dict get $r bench] bm bk bn sw acc fetch comp
        set speed [expr {$acc ? double($sw) / $acc : 0}]
        set width 40
        set bar_acc [expr {max(1, int(round($width * double($acc) / max($sw, $acc))))}]
        set bar_sw  [expr {max(1, int(round($width * double($sw) / max($sw, $acc))))}]
        puts [format "  software     %-40s %10d cycles %10.1f us" \
                  [string repeat # $bar_sw] $sw [expr {$sw / double($carch(mhz))}]]
        if {$acc} {
            puts [format "  accelerator  %-40s %10d cycles %10.1f us   (fetch %d, compute %d)" \
                      [string repeat # $bar_acc] $acc [expr {$acc / double($carch(mhz))}] $fetch $comp]
            puts [format "  speed-up     %.1fx" $speed]
            set row [lreplace $row 7 11 $sw $acc $fetch $comp [format %.2f $speed]]
        } else {
            puts "  accelerator  (none: baseline build, CPU only; C above is the CPU's)"
            set row [lreplace $row 7 11 $sw 0 0 0 {}]
        }
    }
    puts "  result       $verdict"
    set extra_runs [expr {[dict get $after runs] - [dict get $before runs] - 1}]
    if {$extra_runs != 0 || [dict get $after unlocks] != [dict get $before unlocks]} {
        puts "  WARNING: the CPU restarted $extra_runs extra time(s) and the clock lost lock\
              [expr {[dict get $after unlocks] - [dict get $before unlocks]}] time(s) during this job"
    }
    carch_csv $row
    lappend carch(session) $row
    return $r
}

proc carch_csv {row} {
    set path $::carch(out)/results.csv
    set new [expr {![file exists $path]}]
    set fh [open $path a]
    if {$new} {
        puts $fh "job,time,m,k,n,data,seed,sw_cycles,accel_cycles,fetch_cycles,compute_cycles,speedup,result"
    }
    puts $fh [join $row ","]
    close $fh
}

proc carch_check_dims {m k n} {
    foreach {name v} [list M $m K $k N $n] {
        if {![string is integer -strict $v] || $v < 1 || $v > 64} {
            error "$name = $v: M, K and N must be 1..64"
        }
    }
}

# ---------------------------------------------------------------- user commands
proc run_job {m k n {seed 1}} {
    carch_check_dims $m $k $n
    carch_connect
    carch_set ctrl [format %08X [expr {$m | ($k << 7) | ($n << 14)}]]
    carch_set seed [format %08X [expr {$seed & 0xFFFFFFFF}]]
    carch_run "random int8, seed $seed" $m $k $n random $seed
}

proc run_matrix {a b {m 4} {k 4} {n 4}} {
    carch_check_dims $m $k $n
    if {$m * $k > 16 || $k * $n > 16} { error "run_matrix: M*K and K*N must be at most 16 (use run_job)" }
    if {[llength $a] != $m * $k} { error "A needs [expr {$m * $k}] values (M x K = ${m}x${k}), got [llength $a]" }
    if {[llength $b] != $k * $n} { error "B needs [expr {$k * $n}] values (K x N = ${k}x${n}), got [llength $b]" }
    foreach v [concat $a $b] {
        if {![string is integer -strict $v] || $v < -128 || $v > 127} { error "value $v is not an int8 (-128..127)" }
    }
    carch_connect
    carch_set a [carch_pack $a]
    carch_set b [carch_pack $b]
    carch_set ctrl [format %08X [expr {$m | ($k << 7) | ($n << 14) | (1 << 21)}]]
    carch_run "your matrices" $m $k $n matrix -
}

proc carch_summary {rows} {
    puts ""
    puts [format "%-12s %12s %12s %10s  %s" "M x K x N" "software" "accelerator" "speed-up" "result"]
    foreach r $rows {
        lassign $r job time m k n data seed sw acc fetch comp speed verdict
        puts [format "%-12s %12s %12s %10s  %s" "${m}x${k}x${n}" $sw \
                  [expr {$acc ? $acc : "-"}] [expr {$speed ne "" ? "${speed}x" : "-"}] $verdict]
    }
    puts "(cycles at $::carch(mhz) MHz; all rows also in $::carch(out)/results.csv)"
}

proc sweep {sizes {seed 1}} {
    set jobs {}
    foreach s $sizes { lappend jobs [list $s $s $s $seed] }
    sweep_jobs $jobs
}

proc sweep_jobs {jobs} {
    set ::carch(session) {}
    foreach j $jobs {
        lassign $j m k n seed
        if {$seed eq ""} { set seed 1 }
        run_job $m $k $n $seed
    }
    carch_summary $::carch(session)
}

puts "Carch run commands: run_program ?baseline?, run_job M K N ?seed?, run_matrix A B ?M K N?,"
puts "                    sweep {sizes} ?seed?, sweep_jobs {{M K N ?seed?} ...}, board_status"
