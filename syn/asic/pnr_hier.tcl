# ------------------------------------------------------------------------------
# Hierarchical place and route of the systolic array on sky130_fd_sc_hd: the PE
# is a hard macro (built by pnr.tcl with PNR_MACRO=1), placed ROWS x COLS times
# on a grid; only the cells outside the PEs (final adders, tie cells, clock
# tree, hold buffers) are placed here.
#
# Driven by syn/asic/pnr.py through environment variables:
#   PNR_TOP        top module
#   PNR_NETLIST    netlist of the top module in which the PE is a black box
#   PNR_SDC        timing constraints
#   PNR_OUT        output directory
#   PNR_MACRO_DIR  directory with <cell>.lef and <cell>_{tt,ss,ff}.lib
#   PNR_MACRO_CELL name of the macro (gemm_pe)
#   PNR_ROWS, PNR_COLS   size of the array
#   PNR_CHANNEL_X  width of the channels between macro columns, um
#   PNR_CHANNEL_Y  height of the channels between macro rows, um
#   PNR_UTIL       target utilisation of the strip north of the array, where
#                  the final adders go, in percent
#   PNR_DENSITY    global placement density (0..1)
#   PNR_HOLD_MARGIN  slack in ns that hold repair has to leave
#   PNR_PINS       list of "pin-name-pattern region" pairs, as in pnr.tcl
#   PDK_ROOT       directory that contains sky130A
#
# Layout, south at the bottom:
#
#   +--------------------------------------------+
#   |  strip: final adders (gemm_cpa), one per    |
#   |  column, and their output registers         |
#   |   +----+   +----+   +----+   +----+         |
#   |   | PE |   | PE |   | PE |   | PE |  row 0  |
#   |   +----+   +----+   +----+   +----+         |
#   |   +----+   +----+   ...                     |
#   |   | PE |   | PE |                   row 1   |
#   |                                             |
#   +--------------------------------------------+
#
# The channels hold standard cell rows for the clock tree and for buffers, and
# a pair of met4 power straps each. There is a channel on every side of every
# macro, including the outer ones: wires from the pins of the block to the
# macros run there, with the buffers the timing repair puts on them.
# Neighbouring PEs connect with straight wires: the macro has its pins on
# matching tracks on opposite edges. met5 power straps run east-west across the
# macros and connect to their met4 straps.
#
# Hold between PEs is the macro's business (see macro_constraints in pnr.py);
# hold from the block inputs is not repaired here (pnr.py passes constraints
# with a false path for it, see sta_flat.tcl).
# ------------------------------------------------------------------------------

set top     $::env(PNR_TOP)
set out     $::env(PNR_OUT)
set mdir    $::env(PNR_MACRO_DIR)
set mcell   $::env(PNR_MACRO_CELL)
set rows    $::env(PNR_ROWS)
set cols    $::env(PNR_COLS)
set chx     $::env(PNR_CHANNEL_X)
set chy     $::env(PNR_CHANNEL_Y)
set util    $::env(PNR_UTIL)
set density $::env(PNR_DENSITY)
set hold_margin $::env(PNR_HOLD_MARGIN)

set pdk  [file join $::env(PDK_ROOT) sky130A]
set ref  [file join $pdk libs.ref sky130_fd_sc_hd]
set tech [file join $pdk libs.tech openlane]

set t0 [clock seconds]
proc stage {name} {
    puts "\n######## $name (t = [expr {[clock seconds] - $::t0}] s) ########"
    flush stdout
}
proc snap {v grid} { return [format %.3f [expr {$grid * ceil($v / $grid - 1e-6)}]] }

# ------------------------------------------------------------------------------
stage "read design"
# ------------------------------------------------------------------------------
define_corners tt ss ff
foreach {corner lib} {tt tt_025C_1v80 ss ss_100C_1v60 ff ff_n40C_1v95} {
    read_liberty -corner $corner [file join $ref lib sky130_fd_sc_hd__$lib.lib]
    read_liberty -corner $corner [file join $mdir ${mcell}_$corner.lib]
}

read_lef [file join $ref techlef sky130_fd_sc_hd__nom.tlef]
read_lef [file join $ref lef sky130_fd_sc_hd.lef]
read_lef [file join $ref lef sky130_ef_sc_hd.lef]
read_lef [file join $mdir $mcell.lef]

read_verilog $::env(PNR_NETLIST)
link_design $top
read_sdc $::env(PNR_SDC)

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
set db    [ord::get_db]
set block [ord::get_db_block]
set dbu   [$block getDbUnitsPerMicron]
set master [$db findMaster $mcell]
set mw [expr {double([$master getWidth]) / $dbu}]
set mh [expr {double([$master getHeight]) / $dbu}]
set px [expr {$mw + $chx}]
set py [expr {$mh + $chy}]

# Area of the standard cells outside the macros sets the height of the strip.
set std_area 0.0
foreach inst [$block getInsts] {
    set m [$inst getMaster]
    if {[$m getName] ne $mcell} {
        set std_area [expr {$std_area + double([$m getWidth]) * [$m getHeight] / $dbu / $dbu}]
    }
}
set core_w [expr {$cols * $px + $chx}]
set strip  [snap [expr {$std_area / ($util / 100.0) / $core_w}] 5.44]
set core_h [expr {$rows * $py + $chy + $strip}]
set margin_x 5.52
set margin_y 5.44
set die_w [expr {$core_w + 2 * $margin_x}]
set die_h [expr {$core_h + 2 * $margin_y}]
puts [format "macro %.2f x %.2f um, pitch %.2f x %.2f um, strip %.2f um, die %.2f x %.2f um" \
    $mw $mh $px $py $strip $die_w $die_h]

initialize_floorplan -die_area [list 0 0 $die_w $die_h] \
    -core_area [list $margin_x $margin_y [expr {$margin_x + $core_w}] [expr {$margin_y + $core_h}]] \
    -site unithd

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

# PE (i, j) of the netlist goes to row i from the north, column j from the
# west. All origins are multiples of the site width (x) and of two rows (y),
# which puts the macro pins on the routing tracks of the top level.
set placed 0
foreach inst [$block getInsts] {
    if {[[$inst getMaster] getName] ne $mcell} { continue }
    # Instance names look like g_row\[3\].g_col\[5\].u_pe.
    if {![regexp {g_row\\?\[(\d+)\\?\]\.g_col\\?\[(\d+)\\?\]} [$inst getName] -> i j]} {
        error "cannot tell the position of [$inst getName]"
    }
    set x [expr {$margin_x + $chx + $j * $px}]
    set y [expr {$margin_y + $chy + ($rows - 1 - $i) * $py}]
    $inst setOrient R0
    $inst setLocation [expr {round($x * $dbu)}] [expr {round($y * $dbu)}]
    $inst setPlacementStatus FIRM
    incr placed
}
if {$placed != $rows * $cols} { error "placed $placed macros, expected [expr {$rows * $cols}]" }

cut_rows -halo_width_x 0.46 -halo_width_y 0
tapcell -distance 13 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1
source [file join [file dirname [info script]] taps.tcl]
tap_every_row

# Pins of the block. A bus on the west or east edge carries one slice per row
# (a_i: row i is bits 8i .. 8i+7), a bus on the north or south edge one slice
# per column; each slice goes next to its own row or column of macros. Placed
# anywhere along the edge instead, as the pins are placed before the cells, the
# pins of a column ended up hundreds of um away from it, and the final adder
# of the column was pulled apart between them and the macros (a 2 ns wire in
# the adder of one 16 x 16 column). Other pins: anywhere on their edge.
set edge_of {}
foreach {pattern region} $::env(PNR_PINS) {
    dict set edge_of [regsub {\[\*\]$} $pattern ""] [lindex [split $region :] 0]
}
set bits {}
foreach bt [$block getBTerms] {
    if {[regexp {^(\w+)\[(\d+)\]$} [$bt getName] -> base idx] && [dict exists $edge_of $base]} {
        dict lappend bits $base [list $idx [$bt getName]]
    }
}
set sliced {}
set slice {}
foreach base [dict keys $bits] {
    set edge [dict get $edge_of $base]
    set n [expr {$edge in {left right} ? $rows : $cols}]
    set w [llength [dict get $bits $base]]
    if {$w % $n != 0} { continue }
    lappend sliced $base
    foreach item [dict get $bits $base] {
        lassign $item idx name
        dict lappend slice [list $edge [expr {$idx / ($w / $n)}]] $name
    }
}
foreach {pattern region} $::env(PNR_PINS) {
    if {[regsub {\[\*\]$} $pattern ""] ni $sliced} {
        set_io_pin_constraint -pin_names $pattern -region $region
    }
}
foreach key [dict keys $slice] {
    lassign $key edge k
    if {$edge in {left right}} {
        set lo [expr {$margin_y + $chy + ($rows - 1 - $k) * $py}]
        set hi [expr {$lo + $mh}]
    } else {
        set lo [expr {$margin_x + $chx + $k * $px}]
        set hi [expr {$lo + $mw}]
    }
    set_io_pin_constraint -pin_names [dict get $slice $key] -region [format "%s:%.2f-%.2f" $edge $lo $hi]
}
place_pins -hor_layers met3 -ver_layers met2

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
# One VPWR / VGND pair of met4 straps in every vertical channel ...
set w4 1.6
set s4 1.6
add_pdn_stripe -grid grid -layer met4 -width $w4 -spacing $s4 -pitch $px \
    -offset [format %.2f [expr {($chx - 2 * $w4 - $s4) / 2.0}]]
# ... and one pair of met5 straps across every macro row, at heights where the
# macro has its own met4 straps underneath.
set w5 1.6
add_pdn_stripe -grid grid -layer met5 -width $w5 -spacing [format %.2f [expr {$mh * 0.35 - $w5}]] \
    -pitch $py -offset [format %.2f [expr {$chy + $mh * 0.3}]]
add_pdn_connect -grid grid -layers {met1 met4}
add_pdn_connect -grid grid -layers {met4 met5}

define_pdn_grid -macro -default -name macro -starts_with POWER -halo {0 0 0 0}
add_pdn_connect -grid macro -layers {met4 met5}
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
repair_timing -setup -skip_buffering
repair_timing -hold -hold_margin $hold_margin
detailed_placement
check_placement

# ------------------------------------------------------------------------------
stage "routing"
# ------------------------------------------------------------------------------
write_db [file join $out ${top}_placed.odb]
set_routing_layers -signal met1-met5 -clock met3-met5
# Power pins of the cells added since the power grid was built (clock tree
# buffers and loads, timing repair): only the netlist records them, the rails
# connect them in the layout; LVS needs them in the netlist.
global_connect
global_route -congestion_iterations 50 -congestion_report_file [file join $out congestion.rpt]
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

detailed_route -output_drc [file join $out drc.rpt] -verbose 1
# Antennas left once the wires are exact (the repair above worked on the
# global routes): diodes once more and those routes again, as ORFS does.
for {set i 0} {$i < 6 && [check_antennas] > 0} {incr i} {
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

# ------------------------------------------------------------------------------
stage "reports"
# ------------------------------------------------------------------------------
# Timing here uses the timing models of the macro: the paths between PEs and
# from PEs to the final adders, not the paths inside a PE. pnr.py runs a
# separate flat analysis (sta_flat.tcl) with the netlist and parasitics of
# every PE for the complete picture.
set mpins [get_pins -of_objects [get_cells -filter "ref_name == $mcell"]]
set mclk  {}
set min   {}
foreach p $mpins {
    set name [get_property $p lib_pin_name]
    set dir  [get_property $p direction]
    if {$name eq "clk"} { lappend mclk $p } elseif {$dir eq "input"} { lappend min $p }
}
set from [concat [all_registers -clock_pins] $mclk]
set to   [concat [all_registers -data_pins] $min]
foreach corner {tt ss ff} {
    puts "SECTION setup_r2r $corner"
    report_checks -corner $corner -path_delay max -digits 3 -from $from -to $to
    puts "SECTION setup_all $corner"
    report_checks -corner $corner -path_delay max -digits 3
    puts "SECTION hold_all $corner"
    report_checks -corner $corner -path_delay min -digits 3
}
puts "SECTION area"
report_design_area
puts "SECTION clock skew"
report_clock_skew
puts "SECTION power grid"
# Every instance, macros included, connected to the grid (the block has no
# pads, so there are no terminals to start from).
check_power_grid -net VPWR -dont_require_terminals
check_power_grid -net VGND -dont_require_terminals
puts "SECTION end"
puts "elapsed [expr {[clock seconds] - $t0}] s"

write_def     [file join $out $top.def]
write_db      [file join $out $top.odb]
write_verilog [file join $out $top.pnr.v]
