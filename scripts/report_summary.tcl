# Summarise a Vivado build from its text reports (no design is opened, so it
# takes a second). Reads utilization.rpt, timing_summary.rpt and, if present,
# utilization_hier.rpt and power.rpt from one folder, prints a short summary
# and writes it to <folder>/summary.txt.
#
# Vivado Tcl Shell:
#   source C:/carch/scripts/report_summary.tcl
#   report_summary C:/Users/aditi/OneDrive/Desktop/out
#   report_summary                      ;# default: fpga/out next to this repo
# Batch:
#   vivado -mode batch -source scripts/report_summary.tcl -tclargs <folder>
# Any tclsh works too:  tclsh scripts/report_summary.tcl <folder>

proc rs_read {path} {
    set fh [open $path]
    set lines [split [read $fh] "\n"]
    close $fh
    return $lines
}

proc rs_header {lines key} {
    foreach l $lines {
        if {[regexp "^\\|\\s*$key\\s*:\\s*(.*\\S)" $l -> v]} { return $v }
    }
    return "?"
}

# Index of the first line containing text, searching from start.
proc rs_find {lines text {start 0}} {
    for {set i $start} {$i < [llength $lines]} {incr i} {
        if {[string first $text [lindex $lines $i]] >= 0} { return $i }
    }
    return -1
}

proc report_summary {{dir ""}} {
    if {$dir eq ""} {
        set dir [file normalize [file join [file dirname [info script]] .. fpga out]]
        if {![file exists $dir/utilization.rpt]} { set dir [file normalize fpga/out] }
    }
    # fpga/build.tcl names: utilization.rpt, timing_summary.rpt;
    # scripts/vivado_synth.tcl names: post_route_utilization.rpt, post_route_timing.rpt.
    set uf $dir/utilization.rpt
    set tf $dir/timing_summary.rpt
    if {![file exists $uf] && [file exists $dir/post_route_utilization.rpt]} {
        set uf $dir/post_route_utilization.rpt
        set tf $dir/post_route_timing.rpt
    }
    foreach f [list $uf $tf] {
        if {![file exists $f]} { error "$f not found: pass the folder that holds the build reports" }
    }
    set out {}

    # ------------------------------------------------------------ utilization
    set u [rs_read $uf]
    set design [rs_header $u Design]
    set part   [rs_header $u Device]
    set state  [rs_header $u "Design State"]
    lappend out "$design, $part, [string tolower $state] ($dir)"
    lappend out [format "| %-16s | %6s | %9s | %6s |" "Site Type" Used Available Util%]
    foreach site {"Slice LUTs" "Slice Registers" "Block RAM Tile" "DSPs" "Bonded IOB"} {
        foreach l $u {
            if {[regexp "^\\|\\s*$site\\s*\\|\\s*(\[\\d.\]+)\\s*\\|\[^|\]*\\|\[^|\]*\\|\\s*(\[\\d.\]+)\\s*\\|\\s*(\[\\d.\]+)\\s*\\|" \
                    $l -> used avail pct]} {
                lappend out [format "| %-16s | %6s | %9s | %6s |" $site $used $avail $pct]
                break
            }
        }
    }

    # ------------------------------------------------------------ timing
    set t [rs_read $tf]
    set wns ""; set tns ""; set fail ""; set whs ""; set ths ""
    set i [rs_find $t "| Design Timing Summary"]
    for {set j $i} {$i >= 0 && $j < $i + 15} {incr j} {
        if {[regexp {^\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)\s+(-?[\d.]+)} \
                [lindex $t $j] -> wns tns fail total whs ths]} { break }
    }
    # Clock periods, then the clock whose own WNS is the design WNS.
    set periods [dict create]
    set c0 [rs_find $t "| Clock Summary"]
    set c1 [rs_find $t "| Intra Clock Table" [expr {max($c0, 0)}]]
    for {set j $c0} {$c0 >= 0 && $j < $c1} {incr j} {
        if {[regexp {^\s*(\S+)\s+\{[^\}]*\}\s+([\d.]+)\s+([\d.]+)} [lindex $t $j] -> name per freq]} {
            dict set periods $name $per
        }
    }
    set clock ""; set period ""
    for {set j $c1} {$c1 >= 0 && $j < $c1 + 30} {incr j} {
        if {[regexp {^\s*(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)} [lindex $t $j] -> name cw]} {
            if {$wns ne "" && $cw == $wns && [dict exists $periods $name]} {
                set clock $name; set period [dict get $periods $name]; break
            }
        }
    }
    lappend out ""
    lappend out [format "    %8s %8s %8s %8s   %s" "WNS(ns)" "TNS(ns)" "WHS(ns)" "THS(ns)" "failing endpoints"]
    lappend out [format "    %8s %8s %8s %8s   %s" $wns $tns $whs $ths $fail]

    # ------------------------------------------------------------ power
    if {[file exists $dir/power.rpt]} {
        foreach l [rs_read $dir/power.rpt] {
            if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $l -> watts]} {
                lappend out "" "Total on-chip power: $watts W"
                break
            }
        }
    }

    # ------------------------------------------------------------ per block
    if {[file exists $dir/utilization_hier.rpt]} {
        set h [rs_read $dir/utilization_hier.rpt]
        set cols {}
        foreach l $h {
            if {[regexp {^\|\s*Instance\s*\|} $l]} {
                foreach c [lrange [split $l |] 1 end-1] { lappend cols [string trim $c] }
                break
            }
        }
        set want {"Total LUTs" FFs RAMB36 RAMB18 "DSP Blocks"}
        set idx {}
        foreach w $want { lappend idx [lsearch -exact $cols $w] }
        if {[llength $cols] && [lsearch $idx -1] < 0} {
            lappend out "" [format "%-26s %-28s %8s %7s %6s %6s %4s" Instance Module LUTs FFs RAMB36 RAMB18 DSP]
            foreach l $h {
                set f [split $l |]
                if {[llength $f] < [llength $cols] + 2} continue
                set inst [lindex $f 1]
                if {![regexp {^ (\s*)(\S+)\s*$} $inst -> indent name] || $name eq "Instance"} continue
                if {[string length $indent] > 4} continue        ;# top + two levels
                set vals {}
                foreach k $idx { lappend vals [string trim [lindex $f [expr {$k + 1}]]] }
                lappend out [format "%-26s %-28s %8s %7s %6s %6s %4s" \
                    "$indent$name" [string range [string trim [lindex $f 2]] 0 27] {*}$vals]
            }
        }
    }

    # ------------------------------------------------------------ result line
    lappend out ""
    lappend out "RESULT top=$design part=$part clock=$clock period=${period}ns WNS=${wns}ns WHS=${whs}ns"
    if {$wns eq "" || $period eq ""} {
        lappend out "RESULT could not read WNS or the clock period"
    } elseif {$wns >= 0 && ($whs eq "" || $whs >= 0)} {
        lappend out [format "RESULT timing met at %.1f MHz; max clock about %.1f MHz" \
            [expr {1000.0 / $period}] [expr {1000.0 / ($period - $wns)}]]
    } else {
        lappend out [format "RESULT timing NOT met at %.1f MHz" [expr {1000.0 / $period}]]
    }

    set text [join $out "\n"]
    puts $text
    set fh [open $dir/summary.txt w]
    puts $fh $text
    close $fh
    puts "\n(written to $dir/summary.txt)"
}

# Run directly when given a folder (batch mode or tclsh); otherwise just define the proc.
if {[info exists argv] && [llength $argv] > 0} {
    report_summary [lindex $argv 0]
}
