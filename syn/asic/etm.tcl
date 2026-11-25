# ------------------------------------------------------------------------------
# Timing model (Liberty) of a hard macro for one corner, from its routed
# netlist and extracted parasitics (OpenSTA).
#
# One corner per run: OpenROAD 26Q3 writes wrong clock-to-output arcs when
# several corners are defined (write_timing_model -scene ff gave 1.40 ns where
# the flat analysis of the same macro gives 0.52 ns), and the library header
# (voltage, temperature) is only right this way.
#
# Driven by syn/asic/pnr.py through environment variables:
#   ETM_TOP      module name of the macro
#   ETM_CORNER   tt, ss or ff
#   ETM_DIR      directory with <top>.pnr.v, <top>.spef and constraints.sdc;
#                the model is written there as <top>_<corner>.lib
#   PDK_ROOT
# ------------------------------------------------------------------------------

set top $::env(ETM_TOP)
set dir $::env(ETM_DIR)
set corner $::env(ETM_CORNER)
array set lib {tt tt_025C_1v80 ss ss_100C_1v60 ff ff_n40C_1v95}

read_liberty [file join $::env(PDK_ROOT) sky130A libs.ref sky130_fd_sc_hd lib \
    sky130_fd_sc_hd__$lib($corner).lib]
read_verilog [file join $dir $top.pnr.v]
link_design $top
read_sdc [file join $dir constraints.sdc]
set_propagated_clock [all_clocks]
read_spef [file join $dir $top.spef]
write_timing_model -library_name ${top}_$corner [file join $dir ${top}_$corner.lib]
