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
foreach corner {tt ss ff} {
    puts "SECTION setup_r2r $corner"
    report_checks -corner $corner -path_delay max -digits 3 \
        -from [all_registers -clock_pins] -to [all_registers -data_pins]
    puts "SECTION hold_r2r $corner"
    report_checks -corner $corner -path_delay min -digits 3 \
        -from [all_registers -clock_pins] -to [all_registers -data_pins]
    puts "SECTION hold_in $corner"
    report_checks -corner $corner -path_delay min -digits 3 -from [all_inputs]
}
puts "SECTION clock skew"
report_clock_skew
puts "SECTION end"
