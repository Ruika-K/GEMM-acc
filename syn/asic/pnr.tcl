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
#   PNR_HOLD_MARGIN   slack in ns that hold repair has to leave
#   PNR_TIMING_PLACE  1: timing-driven global placement, 0: wire-length-driven
#                 only (much faster on large blocks; timing repair still runs)
#   PNR_PINS      optional list of "pin-name-pattern region" pairs, e.g.
#                 {a_i[*] left:* b_i[*] top:*}; other pins go anywhere
#   PNR_MACRO     1: build a hard macro for syn/asic/pnr_hier.tcl. The pins are
#                 placed by hand (PNR_EDGES), the block is sized on the
#                 placement grid, power and signals stay below met5, and an
#                 abstract (LEF) is written next to the layout (timing models:
#                 etm.tcl)
#   PNR_EDGES     with PNR_MACRO: dict edge -> ordered list of pins, e.g.
#                 {left {a_i[0] a_i[1]} right {a_o[0] a_o[1]}}. Pin k of the
#                 left edge is level with pin k of the right edge, and the
#                 same for top and bottom, so that copies of the macro placed
#                 side by side connect with straight wires
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
set timing_place $::env(PNR_TIMING_PLACE)
set hold_margin  $::env(PNR_HOLD_MARGIN)
set macro   [expr {[info exists ::env(PNR_MACRO)] && $::env(PNR_MACRO)}]

set pdk  [file join $::env(PDK_ROOT) sky130A]
set ref  [file join $pdk libs.ref sky130_fd_sc_hd]
set tech [file join $pdk libs.tech openlane]

set t0 [clock seconds]
proc stage {name} {
    puts "\n######## $name (t = [expr {[clock seconds] - $::t0}] s) ########"
    flush stdout
}

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
if {$macro} {
    # Same core area, but the outline on the grid the macro will be placed on
    # (site width 0.46 um, two rows 5.44 um), so that its pins land on routing
    # tracks and the rows of the top level can be cut cleanly around it. The
    # cells keep 6 sites and one row away from the edge, where the pins are;
    # every um here is paid for once per PE.
    lassign [ord::get_core_area] cx0 cy0 cx1 cy1
    set side [expr {sqrt(($cx1 - $cx0) * ($cy1 - $cy0))}]
    set w [expr {0.46 * ceil(($side + 2 * 2.76) / 0.46)}]
    set h [expr {5.44 * ceil(($side + 2 * 2.72) / 5.44)}]
    initialize_floorplan -die_area [list 0 0 $w $h] \
        -core_area [list 2.76 2.72 [expr {$w - 2.76}] [expr {$h - 2.72}]] -site unithd
}

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

# Pins of a macro, put on tracks by hand: horizontal pins on met3 (pitch
# 0.68 um), vertical ones on met2 (pitch 0.46 um), spread evenly along each edge
# with 4 um kept free at the corners. Opposite edges use the same positions.
proc edge_pins {edges die} {
    lassign $die x0 y0 x1 y1
    foreach {a b layer pitch offset size} {
        left right met3 0.68 0.34 {0.8 0.3}
        top bottom met2 0.46 0.23 {0.14 0.8}
    } {
        set la [expr {[dict exists $edges $a] ? [dict get $edges $a] : {}}]
        set lb [expr {[dict exists $edges $b] ? [dict get $edges $b] : {}}]
        set n [expr {max([llength $la], [llength $lb])}]
        if {$n == 0} { continue }
        set len [expr {$a eq "left" ? $y1 - $y0 : $x1 - $x0}]
        set tracks [expr {int(($len - 2 * 4.0 - $offset) / $pitch)}]
        set step [expr {max(1, $tracks / $n)}]
        set first [expr {($tracks - $step * ($n - 1)) / 2 + int(4.0 / $pitch)}]
        foreach side [list $a $b] pins [list $la $lb] {
            set k 0
            foreach pin $pins {
                set t [format %.3f [expr {$offset + ($first + $k * $step) * $pitch}]]
                switch $side {
                    left   { set loc [list $x0 $t] }
                    right  { set loc [list $x1 $t] }
                    top    { set loc [list $t $y1] }
                    bottom { set loc [list $t $y0] }
                }
                place_pin -pin_name $pin -layer $layer -location $loc -pin_size $size \
                    -force_to_die_boundary
                incr k
            }
        }
    }
}

if {$macro} {
    edge_pins $::env(PNR_EDGES) [ord::get_die_area]
} else {
    if {[info exists ::env(PNR_PINS)]} {
        foreach {pattern region} $::env(PNR_PINS) {
            set_io_pin_constraint -pin_names $pattern -region $region
        }
    }
    place_pins -hor_layers met3 -ver_layers met2
}
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
add_pdn_connect -grid grid -layers {met1 met4}
# A macro stops at met4: the top level runs its met5 straps across it and
# connects them to the macro's met4 straps.
if {!$macro} {
    add_pdn_stripe -grid grid -layer met5 -width 1.6 -pitch $hpitch -offset [snap [expr {$hpitch / 4.0}]]
    add_pdn_connect -grid grid -layers {met4 met5}
}
pdngen

# ------------------------------------------------------------------------------
stage "placement"
# ------------------------------------------------------------------------------
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met5

if {$timing_place} {
    global_placement -density $density -timing_driven
} else {
    global_placement -density $density
}
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
# Setup repair by resizing, pin swapping and cloning only. With buffer insertion
# enabled, this step (OpenROAD 26Q3) leaves chains of up to 50 single-fanout
# buffers on paths it cannot close; they look harmless with placement-based
# wire estimates and become the critical path once routed. Buffering of long
# and high-fanout nets has already been done by the timing-driven placement
# and by repair_design.
repair_timing -setup -skip_buffering
# Hold is repaired with a margin: it is fixed here on wire estimates, and the
# routed wires moved the worst paths by up to 30 ps.
repair_timing -hold -hold_margin $hold_margin
detailed_placement
check_placement

# ------------------------------------------------------------------------------
stage "routing"
# ------------------------------------------------------------------------------
if {$macro} {
    set_routing_layers -signal met1-met4 -clock met3-met4
} else {
    set_routing_layers -signal met1-met5 -clock met3-met5
}
# Power pins of the cells added since the power grid was built (clock tree
# buffers and loads, timing repair): only the netlist records them, the rails
# connect them in the layout; LVS needs them in the netlist.
global_connect
global_route -congestion_iterations 50
estimate_parasitics -global_routing
# Antennas: while the chip is being made, a long wire that so far ends only
# at gates collects charge from the etching and can break them. Diodes give
# the charge a way out (sky130_fd_sc_hd__diode_2, on the do-not-synthesise
# list and therefore kept from every other step). Without this, the routed
# chip had 779 nets over the limits (signoff.py, antenna).
unset_dont_use sky130_fd_sc_hd__diode_2
repair_antennas sky130_fd_sc_hd__diode_2 -iterations 5
set_dont_use sky130_fd_sc_hd__diode_2
check_placement

if {$droute} {
    detailed_route -output_drc [file join $out drc.rpt] -verbose 1
    # Antennas left once the wires are exact (the repair above worked on the
    # global routes): diodes once more and those routes again, as ORFS does.
    for {set i 0} {$i < 3 && [check_antennas] > 0} {incr i} {
        unset_dont_use sky130_fd_sc_hd__diode_2
        repair_antennas sky130_fd_sc_hd__diode_2 -iterations 1
        set_dont_use sky130_fd_sc_hd__diode_2
        detailed_route -output_drc [file join $out drc.rpt] -verbose 1
    }
    filler_placement {sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 \
        sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_1}
    global_connect

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
puts "elapsed [expr {[clock seconds] - $t0}] s"

write_def     [file join $out $top.def]
write_db      [file join $out $top.odb]
write_verilog [file join $out $top.pnr.v]

if {$macro} {
    # What the top level sees of the macro: outline, pins and obstructions.
    # Every layer the macro uses (up to met4) is one obstruction over the whole
    # block, with the pins on its edges. The default instead bloats the drawn
    # shapes and merges them; the merged met2 obstruction then covered part of
    # the pins on the north edge, and the router of the top level found no way
    # to reach them. The drawn shapes without bloating work, but are 43 000
    # rectangles per macro, which made detailed routing of the top level about
    # 50 times slower.
    write_abstract_lef -bloat_occupied_layers [file join $out $top.lef]
    # The timing models are written by etm.tcl, one corner at a time.
}
