# ------------------------------------------------------------------------------
# Flat timing analysis of a hierarchically placed and routed block (OpenSTA):
# the routed netlist of the top level and of the macro, the extracted
# parasitics of the top level and, for every copy of the macro, those of the
# macro. No timing models are involved, so this checks what pnr_hier.tcl saw
# through them, and it covers the paths inside the macros as well.
#
# Driven by syn/asic/pnr.py through environment variables:
#   STA_TOP, STA_SDC
#   STA_TOP_V, STA_TOP_SPEF         routed top level
#   STA_MACRO_V, STA_MACRO_SPEF     routed macro
#   STA_MACRO_CELL                  its module name
#   PDK_ROOT
# ------------------------------------------------------------------------------

set ref [file join $::env(PDK_ROOT) sky130A libs.ref sky130_fd_sc_hd]
define_corners tt ss ff
read_liberty -corner tt [file join $ref lib sky130_fd_sc_hd__tt_025C_1v80.lib]
read_liberty -corner ss [file join $ref lib sky130_fd_sc_hd__ss_100C_1v60.lib]
read_liberty -corner ff [file join $ref lib sky130_fd_sc_hd__ff_n40C_1v95.lib]
# Macros with a single characterised corner (the SRAMs of the chip).
if {[info exists ::env(STA_EXTRA_LIBS)]} {
    foreach lib $::env(STA_EXTRA_LIBS) {
        foreach corner {tt ss ff} { read_liberty -corner $corner $lib }
    }
}

read_verilog $::env(STA_MACRO_V)
read_verilog $::env(STA_TOP_V)
link_design $::env(STA_TOP)
read_sdc $::env(STA_SDC)
set_propagated_clock [all_clocks]

read_spef $::env(STA_TOP_SPEF)
set n 0
foreach inst [get_cells -filter "ref_name == $::env(STA_MACRO_CELL)"] {
    read_spef -path [get_full_name $inst] $::env(STA_MACRO_SPEF)
    incr n
}
puts "parasitics of $n macro instances read"

# Hold is reported in two parts. Between registers (hold_r2r) it has to be met.
# From the block inputs (hold_in) it is left open: the constraints launch the
# inputs at the ideal clock edge, while the registers inside see the clock
# 1 - 2 ns later, after the clock tree; repairing that would put thousands of
# delay buffers in front of the array (3000 at 16 x 16) for a situation that
# does not exist once the array sits next to the registers that drive it. It
# is closed when the block is placed in its surroundings.
# Registers here are flip-flops: the SRAM macros, which OpenSTA counts as
# registers as well, are reported on their own below.
set srams [get_cells -quiet -filter "ref_name =~ sky130_sram_*"]
proc no_sram {pins} {
    set out {}
    foreach p $pins {
        if {![string match sky130_sram_* [get_property [get_cells -of_objects $p] ref_name]]} {
            lappend out $p
        }
    }
    return $out
}
set reg_clk [no_sram [all_registers -clock_pins]]
set reg_d   [no_sram [all_registers -data_pins]]
foreach corner {tt ss ff} {
    puts "SECTION setup_r2r $corner"
    report_checks -corner $corner -path_delay max -digits 3 -from $reg_clk -to $reg_d
    puts "SECTION hold_r2r $corner"
    report_checks -corner $corner -path_delay min -digits 3 -from $reg_clk -to $reg_d
    puts "SECTION hold_in $corner"
    report_checks -corner $corner -path_delay min -digits 3 -from [all_inputs]
}
# Paths that start or end at an SRAM macro. The macro's own part of them (its
# clock-to-output and setup times) comes from a model with one corner that is
# not trustworthy (see docs/results.md); the rest of each path is real, and the
# slack says how much more time the SRAM may take than its model claims. The
# model launches the read data at the falling clock edge, so the paths out of
# a macro have half a cycle.
if {[llength $srams] > 0} {
    set sram_in {}
    foreach p [get_pins -of_objects $srams -filter "direction == input"] {
        if {![string match clk* [get_property $p lib_pin_name]]} { lappend sram_in $p }
    }
    foreach corner {tt ss ff} {
        puts "SECTION setup_sram_out $corner"
        report_checks -corner $corner -path_delay max -digits 3 -from $srams
        puts "SECTION setup_sram_in $corner"
        report_checks -corner $corner -path_delay max -digits 3 -to $sram_in
        puts "SECTION hold_sram $corner"
        report_checks -corner $corner -path_delay min -digits 3 -to $sram_in
    }
}
puts "SECTION clock skew"
report_clock_skew
# Clock arrival at the clock pins of the macros, slow corner: a macro passes
# its results to its neighbours in the array in one cycle, so the difference
# between neighbours is what counts.
puts "SECTION macro clock"
report_checks -corner ss -path_delay max -format end -group_path_count 1 > /dev/null
set arr [dict create]
foreach inst [get_cells -filter "ref_name == $::env(STA_MACRO_CELL)"] {
    if {[regexp {g_row\[(\d+)\]\.g_col\[(\d+)\]} [get_full_name $inst] -> i j]} {
        dict set arr $i,$j [get_property [get_pins [get_full_name $inst]/clk] arrival_max_rise]
    }
}
if {[dict size $arr] > 0} {
    set worst 0.0
    dict for {key a} $arr {
        lassign [split $key ,] i j
        foreach n [list [expr {$i + 1}],$j $i,[expr {$j + 1}]] {
            if {[dict exists $arr $n]} { set worst [expr {max($worst, abs($a - [dict get $arr $n]))}] }
        }
    }
    set v [dict values $arr]
    puts [format "macro clock pins: %d, arrival %.3f .. %.3f ns, worst difference between neighbours %.3f ns" \
        [llength $v] [tcl::mathfunc::min {*}$v] [tcl::mathfunc::max {*}$v] $worst]
}
puts "SECTION end"
