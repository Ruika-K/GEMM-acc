# ------------------------------------------------------------------------------
# Power of the routed chip at the typical corner (OpenSTA), from the switching
# activity of a gate-level simulation (syn/asic/power.py, tb/test_gemm_power.py).
#
# Read as for the flat timing analysis (sta_flat.tcl): routed netlists of the
# top level and of the PE macro, extracted parasitics of both, the SRAM
# models. Then once with OpenSTA's default activity (inputs toggling in 10 %
# of the cycles, propagated through the logic), for comparison, and once with
# the activity from the VCD file of the simulation.
#
# Driven by environment variables:
#   STA_TOP, STA_SDC, STA_TOP_V, STA_TOP_SPEF, STA_MACRO_V, STA_MACRO_SPEF,
#   STA_MACRO_CELL, STA_EXTRA_LIBS, PDK_ROOT   as for sta_flat.tcl
#   POWER_VCD       the VCD file
#   POWER_SCOPE     the netlist's instance in it
#   POWER_PERIOD    clock period of the simulation, ns
# ------------------------------------------------------------------------------

set ref [file join $::env(PDK_ROOT) sky130A libs.ref sky130_fd_sc_hd]
read_liberty [file join $ref lib sky130_fd_sc_hd__tt_025C_1v80.lib]
foreach lib $::env(STA_EXTRA_LIBS) { read_liberty $lib }
read_verilog $::env(STA_MACRO_V)
read_verilog $::env(STA_TOP_V)
link_design $::env(STA_TOP)
read_sdc $::env(STA_SDC)
# The clock of the simulation (the constraints may use another period).
create_clock -name clk -period $::env(POWER_PERIOD) [get_ports aclk]
set_propagated_clock [all_clocks]
read_spef $::env(STA_TOP_SPEF)
foreach inst [get_cells -filter "ref_name == $::env(STA_MACRO_CELL)"] {
    read_spef -path [get_full_name $inst] $::env(STA_MACRO_SPEF)
}

puts "SECTION default_activity"
report_power -digits 5

puts "SECTION vcd"
read_vcd -scope $::env(POWER_SCOPE) $::env(POWER_VCD)
report_activity_annotation
report_power -digits 5

# Breakdown: the 64 PE macros (everything inside them, their own clock tree
# included), the SRAMs, and the clock buffers of the top level (clock tree
# synthesis and the hand-built PE tree); the rest is the difference.
set pes   [get_cells -filter "ref_name == $::env(STA_MACRO_CELL)" u_core/u_array/*]
set srams [get_cells -hierarchical -filter "ref_name =~ sky130_sram_*"]
set clkbufs [get_cells {clkbuf_* delaybuf_* clkload* pe_ctree_*}]
puts "SECTION instances"
report_power -digits 6 -instances [concat $pes $srams $clkbufs]

# The SRAM models charge the same energy on every clock edge, selected or not
# (see docs/results.md); the fraction of cycles in which a port is selected
# (chip select low) gives the lower bound.
puts "SECTION sram_duty"
foreach c $srams {
    set d {}
    foreach pn {csb0 csb1} { lappend d [lindex [get_property [get_pins [get_full_name $c]/$pn] activity] 1] }
    puts "SRAM [get_full_name $c] [join $d { }]"
}
puts "SECTION end"
