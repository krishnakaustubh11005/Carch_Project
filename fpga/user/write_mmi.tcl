# Describe where soc_top's 64 KB RAM sits in the routed design, as an .mmi
# file for updatemem (fpga/user/README.md). updatemem then swaps the program
# inside an existing fpga_top.bit in seconds, without a rebuild.
#   vivado -mode batch -source fpga/user/write_mmi.tcl -tclargs <post_route.dcp> <out.mmi>
# Or, with a routed design already open: source it and call carch_write_mmi <out.mmi>.
#
# Vivado splits the 16384 x 32-bit RAM over RAMB36 cells; each cell holds a
# bit slice (ram_slice_begin..end) of every word (ram_addr_begin..end).
# MemType is the data-only size updatemem expects (RAMB36 -> RAMB32).
# updatemem's "processor" view: one 32-bit little-endian bus, byte addresses
# 0x0000-0xFFFF, word w at byte address 4*w.

proc carch_write_mmi {path} {
    set cells [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *u_soc/u_ram/*}]
    if {[llength $cells] == 0} { error "no RAM BRAM cells (u_soc/u_ram) in the open design" }
    set lanes {}
    foreach c $cells {
        set loc [get_property LOC $c]
        regsub {^RAMB\d+_} $loc {} placement
        lappend lanes [list [get_property ram_slice_end $c] [get_property ram_slice_begin $c] \
                           [get_property ram_addr_begin $c] [get_property ram_addr_end $c] \
                           [expr {[string match RAMB18* [get_property REF_NAME $c]] ? "RAMB16" : "RAMB32"}] \
                           $placement]
    }
    # Highest bits first.
    set lanes [lsort -integer -decreasing -index 0 $lanes]
    set words [expr {[lindex $lanes 0 3] + 1}]
    set f [open $path w]
    puts $f "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    puts $f "<MemInfo Version=\"1\" Minor=\"0\">"
    puts $f "  <Processor Endianness=\"Little\" InstPath=\"carch\">"
    puts $f "    <AddressSpace Name=\"ram\" Begin=\"0\" End=\"[expr {4 * $words - 1}]\">"
    puts $f "      <BusBlock>"
    foreach l $lanes {
        lassign $l msb lsb begin end type placement
        puts $f "        <BitLane MemType=\"$type\" Placement=\"$placement\">"
        puts $f "          <DataWidth MSB=\"$msb\" LSB=\"$lsb\"/>"
        puts $f "          <AddressRange Begin=\"$begin\" End=\"$end\"/>"
        puts $f "          <Parity ON=\"false\" NumBits=\"0\"/>"
        puts $f "        </BitLane>"
    }
    puts $f "      </BusBlock>"
    puts $f "    </AddressSpace>"
    puts $f "  </Processor>"
    puts $f "  <Config>"
    puts $f "    <Option Name=\"Part\" Val=\"[get_property PART [current_design]]\"/>"
    puts $f "  </Config>"
    puts $f "  <DRC>"
    puts $f "    <Rule Name=\"RDADDRCHANGE\" Val=\"false\"/>"
    puts $f "  </DRC>"
    puts $f "</MemInfo>"
    close $f
    puts "==== wrote $path ([llength $lanes] BRAM lanes, $words words) ===="
}

# Standalone use only (build.tcl sources this file with its own arguments).
if {$argc >= 2 && [string match -nocase *.dcp [lindex $argv 0]]} {
    open_checkpoint [lindex $argv 0]
    carch_write_mmi [lindex $argv 1]
}
