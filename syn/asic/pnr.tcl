# ------------------------------------------------------------------------------
# OpenROAD place and route for one block on sky130_fd_sc_hd.
#
# Driven by syn/asic/pnr.py through environment variables:
#   PNR_TOP       top module of the netlist
#   PNR_NETLIST   synthesised netlist (from syn/asic/run.py)
#   PNR_SDC       timing constraints
#   PNR_OUT       output directory
#   PNR_UTIL      target core utilisation in percent
#   PNR_DENSITY   global placement density (0..1)
#   PNR_DROUTE    1: detailed route and extract parasitics, 0: stop after
#                 global route and use its wire estimates
#   PNR_PINS      optional list of "pin-name-pattern region" pairs, e.g.
#                 {a_i[*] left:* b_i[*] top:*}; other pins go anywhere
#   PDK_ROOT      directory that contains sky130A
#
# Steps: floorplan -> power grid -> placement -> clock tree -> timing repair ->
# routing -> parasitics -> reports.
# ------------------------------------------------------------------------------

set top     $::env(PNR_TOP)
set out     $::env(PNR_OUT)
set util    $::env(PNR_UTIL)
set density $::env(PNR_DENSITY)
set droute  $::env(PNR_DROUTE)

set pdk  [file join $::env(PDK_ROOT) sky130A]
set ref  [file join $pdk libs.ref sky130_fd_sc_hd]
set tech [file join $pdk libs.tech openlane]

proc stage {name} { puts "\n######## $name ########" }

# ------------------------------------------------------------------------------
stage "read design"
# ------------------------------------------------------------------------------
define_corners tt ss ff
read_liberty -corner tt [file join $ref lib sky130_fd_sc_hd__tt_025C_1v80.lib]
read_liberty -corner ss [file join $ref lib sky130_fd_sc_hd__ss_100C_1v60.lib]
read_liberty -corner ff [file join $ref lib sky130_fd_sc_hd__ff_n40C_1v95.lib]

read_lef [file join $ref techlef sky130_fd_sc_hd__nom.tlef]
read_lef [file join $ref lef sky130_fd_sc_hd.lef]
read_lef [file join $ref lef sky130_ef_sc_hd.lef]

read_verilog $::env(PNR_NETLIST)
link_design $top
read_sdc $::env(PNR_SDC)

# Cells the PDK excludes from optimisation, as in synthesis.
set dont_use {}
foreach f {no_synth.cells drc_exclude.cells} {
    set fh [open [file join $tech sky130_fd_sc_hd $f]]
    foreach cell [split [read $fh]] { if {$cell ne ""} { lappend dont_use $cell } }
    close $fh
}
set_dont_use $dont_use

# ------------------------------------------------------------------------------
stage "floorplan"
# ------------------------------------------------------------------------------
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 5.52 -site unithd

# Routing tracks: layer, direction, offset, pitch.
set fh [open [file join $tech sky130_fd_sc_hd tracks.info]]
while {[gets $fh line] >= 0} {
    lassign $line layer dir offset pitch
    set track($layer,$dir) [list $offset $pitch]
}
close $fh
foreach layer {li1 met1 met2 met3 met4 met5} {
    lassign $track($layer,X) xo xp
    lassign $track($layer,Y) yo yp
    make_tracks $layer -x_offset $xo -x_pitch $xp -y_offset $yo -y_pitch $yp
}

if {[info exists ::env(PNR_PINS)]} {
    foreach {pattern region} $::env(PNR_PINS) {
        set_io_pin_constraint -pin_names $pattern -region $region
    }
}
place_pins -hor_layers met3 -ver_layers met2
tapcell -distance 13 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1

# ------------------------------------------------------------------------------
stage "power grid"
# ------------------------------------------------------------------------------
add_global_connection -net VPWR -pin_pattern {^VPWR$} -power
add_global_connection -net VPWR -pin_pattern {^VPB$}
add_global_connection -net VGND -pin_pattern {^VGND$} -ground
add_global_connection -net VGND -pin_pattern {^VNB$}
global_connect

set_voltage_domain -power VPWR -ground VGND
define_pdn_grid -name grid
add_pdn_stripe -grid grid -layer met1 -width 0.48 -followpins
# The PDK's default strap pitch (153.6 um) is wider than a small block, so the
# pitch is reduced until at least two pairs of straps fit.
set core [ord::get_core_area]
set core_w [expr {[lindex $core 2] - [lindex $core 0]}]
set core_h [expr {[lindex $core 3] - [lindex $core 1]}]
proc snap {v} { return [format %.2f [expr {round($v / 0.02) * 0.02}]] }   ;# manufacturing grid
set vpitch [snap [expr {min(153.6,  $core_w / 2.0)}]]
set hpitch [snap [expr {min(153.18, $core_h / 2.0)}]]
add_pdn_stripe -grid grid -layer met4 -width 1.6 -pitch $vpitch -offset [snap [expr {$vpitch / 4.0}]]
add_pdn_stripe -grid grid -layer met5 -width 1.6 -pitch $hpitch -offset [snap [expr {$hpitch / 4.0}]]
add_pdn_connect -grid grid -layers {met1 met4}
add_pdn_connect -grid grid -layers {met4 met5}
pdngen

# ------------------------------------------------------------------------------
stage "placement"
# ------------------------------------------------------------------------------
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met5

global_placement -density $density -timing_driven
estimate_parasitics -placement
repair_design
detailed_placement

# ------------------------------------------------------------------------------
stage "clock tree"
# ------------------------------------------------------------------------------
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_16 \
    -buf_list {sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_2}
set_propagated_clock [all_clocks]
repair_clock_nets
detailed_placement

# ------------------------------------------------------------------------------
stage "timing repair"
# ------------------------------------------------------------------------------
estimate_parasitics -placement
repair_timing -setup
repair_timing -hold
detailed_placement
check_placement

# ------------------------------------------------------------------------------
stage "routing"
# ------------------------------------------------------------------------------
set_routing_layers -signal met1-met5 -clock met3-met5
global_route -congestion_iterations 50
estimate_parasitics -global_routing

if {$droute} {
    detailed_route -output_drc [file join $out drc.rpt] -verbose 1
    filler_placement {sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 \
        sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_1}

    stage "parasitic extraction"
    define_process_corner -ext_model_index 0 X
    extract_parasitics -ext_model_file [file join $tech rules.openrcx.sky130A.nom.spef_extractor]
    write_spef [file join $out $top.spef]
    read_spef  [file join $out $top.spef]
}

# ------------------------------------------------------------------------------
stage "reports"
# ------------------------------------------------------------------------------
foreach corner {tt ss ff} {
    puts "SECTION setup_r2r $corner"
    report_checks -corner $corner -path_delay max -digits 3 \
        -from [all_registers -clock_pins] -to [all_registers -data_pins]
    puts "SECTION setup_all $corner"
    report_checks -corner $corner -path_delay max -digits 3
    puts "SECTION hold_all $corner"
    report_checks -corner $corner -path_delay min -digits 3
}
puts "SECTION area"
report_design_area
puts "SECTION clock skew"
report_clock_skew
puts "SECTION power"
report_power -corner tt
puts "SECTION end"

write_def     [file join $out $top.def]
write_db      [file join $out $top.odb]
write_verilog [file join $out $top.pnr.v]
