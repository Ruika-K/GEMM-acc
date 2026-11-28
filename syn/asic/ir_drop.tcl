# ------------------------------------------------------------------------------
# Static IR drop of a routed block (OpenROAD's PDNSim, syn/asic/ir_drop.py).
#
# Every instance draws its average current from the power grid; PDNSim builds
# the resistor network of the grid (stripes, rails, vias) from the layout and
# solves for the voltage at every node, VPWR and VGND alike (for VGND the
# "drop" is how far the ground rises). The currents come from the power of
# each instance at the typical corner, with the switching activity of a
# gate-level simulation (as power.tcl) where the libraries have power, and
# given per instance where they have none (the PE macros: their timing model
# carries no power).
#
# Driven by environment variables:
#   IR_LIBS         Liberty files
#   IR_DB           routed database
#   IR_SDC          constraints
#   IR_SPEF         extracted parasitics (optional)
#   IR_CLOCK_PORT   clock port, IR_PERIOD the clock period of the simulation, ns
#   IR_VCD          VCD file of the simulation, IR_SCOPE the block's instance in it
#   IR_INST_POWER   optional file of lines "<instance> <power in W>"
#   IR_CASES        "<name> <source> ..." pairs: source BUMPS, STRAPS, FULL or
#                   a voltage source file (x, y, size, voltage per line, um;
#                   %NET% in its name stands for VPWR or VGND)
#   IR_OUT          directory for the voltage files
# ------------------------------------------------------------------------------

foreach lib $::env(IR_LIBS) { read_liberty $lib }
read_db $::env(IR_DB)
read_sdc $::env(IR_SDC)
create_clock -name clk -period $::env(IR_PERIOD) [get_ports $::env(IR_CLOCK_PORT)]
set_propagated_clock [all_clocks]
if {[info exists ::env(IR_SPEF)] && $::env(IR_SPEF) ne ""} { read_spef $::env(IR_SPEF) }
read_vcd -scope $::env(IR_SCOPE) $::env(IR_VCD)

# Every pin should get its activity from the VCD file. (The count of
# unannotated pins can come out negative, printed as a huge number, when pins
# are counted twice; the list below is what counts.)
puts "SECTION activity"
report_activity_annotation -report_unannotated
puts "SECTION unannotated end"
puts "SECTION power"
report_power -digits 5

# Power given per instance (added to what the libraries give, which for these
# instances is nothing).
set given 0.0
set n 0
if {[info exists ::env(IR_INST_POWER)] && $::env(IR_INST_POWER) ne ""} {
    set f [open $::env(IR_INST_POWER)]
    while {[gets $f line] >= 0} {
        set fields [split [string trim $line] " "]
        if {[llength $fields] != 2} continue
        # The database has the names as the DEF writes them, brackets escaped.
        set name [string map {[ \\[ ] \\]} [lindex $fields 0]]
        set p [lindex $fields 1]
        set_pdnsim_inst_power -inst $name -power $p
        set given [expr {$given + $p}]
        incr n
    }
    close $f
}
puts [format "given power: %d instances, %.6f W" $n $given]

foreach {name source} $::env(IR_CASES) {
    foreach net {VPWR VGND} {
        puts "SECTION ir $name $net"
        set args [list -net $net -voltage_file [file join $::env(IR_OUT) ${name}_$net.csv]]
        set file [string map [list %NET% $net] $source]
        if {[file exists $file]} {
            lappend args -vsrc $file
        } else {
            lappend args -source_type $source
        }
        analyze_power_grid {*}$args
    }
}
puts "SECTION end"
