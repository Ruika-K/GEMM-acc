# ------------------------------------------------------------------------------
# Place and route of the complete chip (gemm_top) on sky130_fd_sc_hd: the PE as
# a hard macro (pnr.tcl, PNR_MACRO=1) tiled ROWS x COLS times, the operand
# memories as OpenRAM SRAM macros (syn/asic/gemm_mem_sky130.sv), and all other
# logic as standard cells: skew and de-skew lines, final adders, output FIFO,
# controller, sequencer, loader, AXI interfaces.
#
# Driven by syn/asic/pnr.py through environment variables:
#   PNR_TOP, PNR_NETLIST, PNR_SDC, PNR_OUT, PNR_DENSITY, PNR_HOLD_MARGIN, PDK_ROOT
#   PNR_MACRO_DIR, PNR_MACRO_CELL   the PE macro, as for pnr_hier.tcl
#   PNR_ROWS, PNR_COLS, PNR_CHANNEL_X, PNR_CHANNEL_Y   the PE grid, as there
#   PNR_SRAM_LEFS   abstracts of the SRAM macros (with obstructions, see pnr.py)
#   PNR_SRAM_LIBS   their timing models (one corner, used for all three)
#   PNR_PE_CLK_LATE ns the flip-flops in the PEs get the clock after the
#                   registers around the array (slow corner, see pnr.py)
#   PNR_SRAM_CLK_EARLY ns the SRAM clock pins get the clock before those
#                   registers (slow corner, see pnr.py)
#   PNR_RESUME      optional: cts starts again from the checkpoint written before
#                   the clock tree, route (or 1) from the one before routing
#
# Floorplan, following the data (south at the bottom):
#
#          +-----------------------------+
#          |   B memory, 2 x 2 macros     |  read port facing south
#          +-----------------------------+
#                final adders, de-skew,
#                output FIFO (standard cells)
#   +---------+  +-------------------+
#   | A memory|  |  PE array         |
#   | 2 x 2   |  |  ROWS x COLS      |
#   +---------+  +-------------------+
#   +-----------------------------------+
#   |  bias memory, 2 x 4 macros         |  read port facing north
#   +-----------------------------------+
#
# A word of A holds one operand per array row: lanes 0 - 3 (rows 0 - 3) are in
# the upper pair of A macros, next to the northern half of the array. Likewise
# the left pair of B macros holds columns 0 - 3. The two macros of a pair are
# the two halves of the address range.
# ------------------------------------------------------------------------------

set top     $::env(PNR_TOP)
set out     $::env(PNR_OUT)
set mdir    $::env(PNR_MACRO_DIR)
set mcell   $::env(PNR_MACRO_CELL)
set rows    $::env(PNR_ROWS)
set cols    $::env(PNR_COLS)
set chx     $::env(PNR_CHANNEL_X)
set chy     $::env(PNR_CHANNEL_Y)
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
# Round up to a multiple of grid.
proc snap {v grid} { return [expr {$grid * ceil($v / $grid - 1e-6)}] }

# PNR_RESUME=cts starts from the database saved after placement
# (<top>_pre_cts.odb), PNR_RESUME=route from the one saved before routing
# (<top>_placed.odb).
set resume [expr {[info exists ::env(PNR_RESUME)] ? $::env(PNR_RESUME) : ""}]
if {$resume eq "1"} { set resume route }

# ------------------------------------------------------------------------------
stage "read design"
# ------------------------------------------------------------------------------
define_corners tt ss ff
foreach {corner lib} {tt tt_025C_1v80 ss ss_100C_1v60 ff ff_n40C_1v95} {
    read_liberty -corner $corner [file join $ref lib sky130_fd_sc_hd__$lib.lib]
    read_liberty -corner $corner [file join $mdir ${mcell}_$corner.lib]
    foreach lib $::env(PNR_SRAM_LIBS) { read_liberty -corner $corner $lib }
}

read_lef [file join $ref techlef sky130_fd_sc_hd__nom.tlef]
read_lef [file join $ref lef sky130_fd_sc_hd.lef]
read_lef [file join $ref lef sky130_ef_sc_hd.lef]
read_lef [file join $mdir $mcell.lef]
foreach lef $::env(PNR_SRAM_LEFS) { read_lef $lef }

if {$resume eq "route"} {
    read_db [file join $out ${top}_placed.odb]
} elseif {$resume eq "cts"} {
    read_db [file join $out ${top}_pre_cts.odb]
} else {
    read_verilog $::env(PNR_NETLIST)
    link_design $top
}
read_sdc $::env(PNR_SDC)

set dont_use {}
foreach f {no_synth.cells drc_exclude.cells} {
    set fh [open [file join $tech sky130_fd_sc_hd $f]]
    foreach cell [split [read $fh]] { if {$cell ne ""} { lappend dont_use $cell } }
    close $fh
}
set_dont_use $dont_use
# Wire models for the estimates before extraction (not kept in a checkpoint).
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met5

set db    [ord::get_db]
set block [ord::get_db_block]
set dbu   [$block getDbUnitsPerMicron]

if {$resume eq ""} {
# ------------------------------------------------------------------------------
stage "floorplan"
# ------------------------------------------------------------------------------
proc size_of {name} {
    set m [[ord::get_db] findMaster $name]
    return [list [expr {double([$m getWidth]) / $::dbu}] [expr {double([$m getHeight]) / $::dbu}]]
}
lassign [size_of $mcell] mw mh
lassign [size_of sky130_sram_2kbyte_1rw1r_32x512_8] w2 h2
lassign [size_of sky130_sram_1kbyte_1rw1r_32x256_8] w1 h1
set px [expr {$mw + $chx}]
set py [expr {$mh + $chy}]

# Sizes of the blocks, gaps between them, all on the placement grid.
set gap_m  81.6      ;# between two SRAM macros: room for their read buses (40.8
                     ;# left 2 global routing overflows between the A macros)
set gap_x  150.42    ;# A memory to array: the skew lines of A
set gap_s  152.32    ;# bias memory to array
set gap_n  402.56    ;# array to B memory: final adders, de-skew, output FIFO, skew lines of B
set edge   59.84     ;# core boundary to the outer macros

set arr_w [expr {$cols * $px + $chx}]
set arr_h [expr {$rows * $py + $chy}]
set a_w   [expr {2 * $w2 + $gap_m}]
set a_h   [expr {2 * $h2 + $gap_m}]
set b_w   $a_w
set b_h   $a_h
set s_w   [expr {4 * $w1 + 3 * $gap_m}]
set s_h   [expr {2 * $h1 + $gap_m}]

# Lower left corners, relative to the core origin first: the bias memory at
# the bottom left, the array above it to the right of the A memory, the B
# memory above the array, aligned with its east edge (it is wider than the
# array and would otherwise widen the chip).
set s_x  $edge
set s_y  $edge
set a_x  $edge
set arr_x [expr {$edge + $a_w + $gap_x}]
set arr_y [expr {$s_y + $s_h + $gap_s}]
set a_y  [expr {$arr_y + ($arr_h - $a_h) / 2.0}]
set b_x  [expr {max($edge, $arr_x + $arr_w - $b_w)}]
set b_y  [expr {$arr_y + $arr_h + $gap_n}]

set core_w [snap [expr {$edge + max(max($arr_x + $arr_w, $b_x + $b_w), $s_x + $s_w)}] 0.46]
set core_h [snap [expr {$edge + $b_y + $b_h}] 5.44]
set margin_x 5.52
set margin_y 5.44
set die_w [expr {$core_w + 2 * $margin_x}]
set die_h [expr {$core_h + 2 * $margin_y}]
set cx0  $margin_x
set cy0  $margin_y

# To die coordinates, on the placement grid.
foreach v {s_x a_x arr_x b_x} { set $v [snap [expr {[set $v] + $cx0}] 0.46] }
foreach v {s_y a_y arr_y b_y} { set $v [snap [expr {[set $v] + $cy0}] 5.44] }

puts [format "die %.0f x %.0f um; array %.0f x %.0f at (%.0f, %.0f); A at (%.0f, %.0f); B at (%.0f, %.0f); bias at (%.0f, %.0f)" \
    $die_w $die_h $arr_w $arr_h $arr_x $arr_y $a_x $a_y $b_x $b_y $s_x $s_y]

initialize_floorplan -die_area [list 0 0 $die_w $die_h] \
    -core_area [list $cx0 $cy0 [expr {$cx0 + $core_w}] [expr {$cy0 + $core_h}]] -site unithd

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

proc put {inst x y orient} {
    $inst setOrient $orient
    $inst setLocation [expr {round([snap $x 0.46] * $::dbu)}] [expr {round([snap $y 2.72] * $::dbu)}]
    $inst setPlacementStatus FIRM
}

set n_pe 0
set n_sram 0
foreach inst [$block getInsts] {
    set master [[$inst getMaster] getName]
    set name [$inst getName]
    if {$master eq $mcell} {
        # PE (i, j): row i from the north, column j from the west.
        if {![regexp {g_row\\?\[(\d+)\\?\]\.g_col\\?\[(\d+)\\?\]} $name -> i j]} {
            error "cannot tell the position of $name"
        }
        put $inst [expr {$arr_x + $chx + $j * $px}] [expr {$arr_y + $chy + ($rows - 1 - $i) * $py}] R0
        incr n_pe
    } elseif {[string match sky130_sram_* $master]} {
        if {![regexp {(u_a_mem|u_b_mem|u_bias_mem).*g_r\\?\[(\d+)\\?\]\.g_c\\?\[(\d+)\\?\]} $name -> mem r c]} {
            error "cannot tell the position of $name"
        }
        switch $mem {
            u_a_mem {
                # Column c holds lanes 4c .. 4c+3 = array rows: c = 0 on top.
                # Row r is an address half: side by side. Read port north.
                put $inst [expr {$a_x + $r * ($w2 + $gap_m)}] [expr {$a_y + (1 - $c) * ($h2 + $gap_m)}] R0
            }
            u_b_mem {
                # Column c holds array columns 4c .. 4c+3: c = 0 on the left.
                # Mirrored, so the read port faces the array.
                put $inst [expr {$b_x + $c * ($w2 + $gap_m)}] [expr {$b_y + $r * ($h2 + $gap_m)}] MX
            }
            u_bias_mem {
                # Column c = array column c: 0 - 3 in the upper row, next to
                # the array. Read port north.
                put $inst [expr {$s_x + ($c % 4) * ($w1 + $gap_m)}] [expr {$s_y + (1 - $c / 4) * ($h1 + $gap_m)}] R0
            }
        }
        incr n_sram
    }
}
puts "placed $n_pe PE macros and $n_sram SRAM macros"
if {$n_pe != $rows * $cols} { error "expected [expr {$rows * $cols}] PE macros" }

cut_rows -halo_width_x 0.46 -halo_width_y 0
tapcell -distance 13 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1

# Pins: AXI4-Lite and the input stream on the west edge, the output stream on
# the north edge, clock, reset and interrupt on the south edge.
set_io_pin_constraint -pin_names {s_axi_* s_axis_*} -region left:*
set_io_pin_constraint -pin_names {m_axis_*} -region top:*
set_io_pin_constraint -pin_names {aclk aresetn irq_o} -region bottom:*
place_pins -hor_layers met3 -ver_layers met2

# ------------------------------------------------------------------------------
stage "power grid"
# ------------------------------------------------------------------------------
add_global_connection -net VPWR -pin_pattern {^VPWR$} -power
add_global_connection -net VPWR -pin_pattern {^VPB$}
add_global_connection -net VPWR -pin_pattern {^vccd1$} -power
add_global_connection -net VGND -pin_pattern {^VGND$} -ground
add_global_connection -net VGND -pin_pattern {^VNB$}
add_global_connection -net VGND -pin_pattern {^vssd1$} -ground
global_connect

set_voltage_domain -power VPWR -ground VGND
define_pdn_grid -name grid
add_pdn_stripe -grid grid -layer met1 -width 0.48 -followpins
# The grid of the array (see pnr_hier.tcl), continued over the whole core: a
# pair of met4 straps in every channel between PE columns and at the same
# pitch elsewhere, a pair of met5 straps across every row of PEs and at the
# same pitch elsewhere. Offsets are relative to the core origin.
set w4 1.6
set s4 1.6
set w5 1.6
set off4 [expr {fmod($arr_x - $cx0, $px) + ($chx - 2 * $w4 - $s4) / 2.0}]
set off5 [expr {fmod($arr_y - $cy0, $py) + $chy + $mh * 0.3}]
add_pdn_stripe -grid grid -layer met4 -width $w4 -spacing $s4 -pitch $px -offset [format %.2f $off4]
add_pdn_stripe -grid grid -layer met5 -width $w5 -spacing [format %.2f [expr {$mh * 0.35 - $w5}]] \
    -pitch $py -offset [format %.2f $off5]
add_pdn_connect -grid grid -layers {met1 met4}
add_pdn_connect -grid grid -layers {met4 met5}

# PEs and SRAMs: met4 straps / rings under the met5 straps.
define_pdn_grid -macro -cells $mcell -name pe -starts_with POWER -halo {0 0 0 0}
add_pdn_connect -grid pe -layers {met4 met5}
define_pdn_grid -macro -cells {sky130_sram_1kbyte_1rw1r_32x256_8 sky130_sram_2kbyte_1rw1r_32x512_8} \
    -name sram -starts_with POWER -halo {2 2 2 2}
add_pdn_connect -grid sram -layers {met4 met5}
pdngen

# ------------------------------------------------------------------------------
stage "placement"
# ------------------------------------------------------------------------------
global_placement -density $density -timing_driven
estimate_parasitics -placement
repair_design
detailed_placement
write_db [file join $out ${top}_pre_cts.odb]
}

if {$resume ne "route"} {
# ------------------------------------------------------------------------------
stage "clock tree"
# ------------------------------------------------------------------------------
# The PEs get an H-tree built by hand (pe_clock_tree.tcl): left to clock tree
# synthesis, which builds one tree for all macros, the PEs came out in groups
# with 0.3 - 0.5 ns between neighbours. The synthesis builds the trees of the
# registers and of the SRAMs; the PE tree is then driven from the clock port
# and delayed until the flip-flops inside the PEs get the clock PNR_PE_CLK_LATE
# after the registers around the array, at the slow corner. The clock tree
# inside a PE is taken from its timing model.
if {$rows != $cols} { error "the PE clock tree needs a square array" }
source [file join [file dirname [info script]] pe_clock_tree.tcl]
set fh [open [file join $mdir ${mcell}_ss.lib]]
if {![regexp {timing_type : max_clock_tree_path;\s*cell_rise\(scalar\) \{\s*values\("([0-9.]+)"\)} [read $fh] -> pe_internal]} {
    error "no max_clock_tree_path in the slow-corner model of $mcell"
}
close $fh
pe_htree_build $mcell $rows
# The clock gate of the datapath (CLOCK_GATING), if there is one, is taken out
# of the synthesis as well and connected afterwards (clock_gate.tcl); the net
# behind it becomes a clock root of its own.
source [file join [file dirname [info script]] clock_gate.tcl]
set cts_roots {}
if {[cg_find] ne ""} { set cts_roots [list -clk_nets [list aclk [cg_detach]]] }
detailed_placement

# No dummy loads: with the gated datapath tree, two of them found no room in
# the placement.
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_16 \
    -buf_list {sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_2} \
    -dont_use_dummy_load {*}$cts_roots
set_propagated_clock [all_clocks]
repair_clock_nets
detailed_placement
estimate_parasitics -placement
if {[cg_find] ne ""} { cg_connect }
pe_htree_connect $mcell $pe_internal $::env(PNR_PE_CLK_LATE)
# The SRAMs get the clock PNR_SRAM_CLK_EARLY before the registers around the
# array (sram_clock.tcl): their read data has half a cycle, their inputs a
# whole one.
source [file join [file dirname [info script]] sram_clock.tcl]
sram_clock_early $::env(PNR_SRAM_CLK_EARLY)
detailed_placement

# ------------------------------------------------------------------------------
stage "timing repair"
# ------------------------------------------------------------------------------
estimate_parasitics -placement
repair_timing -setup -skip_buffering
repair_timing -hold -hold_margin $hold_margin
detailed_placement
check_placement

}

# ------------------------------------------------------------------------------
stage "routing"
# ------------------------------------------------------------------------------
if {$resume ne "route"} { write_db [file join $out ${top}_placed.odb] }
set_propagated_clock [all_clocks]
set_routing_layers -signal met1-met5 -clock met3-met5
# Power pins of the cells added since the power grid was built (clock tree
# buffers and loads, timing repair): only the netlist records them, the rails
# connect them in the layout; LVS needs them in the netlist.
global_connect
# A few overflows next to the SRAM pins are left to detailed routing, which
# has the exact shapes; the DRC count after detailed routing is what counts.
global_route -congestion_iterations 50 -allow_congestion \
    -congestion_report_file [file join $out congestion.rpt]
estimate_parasitics -global_routing
# Antennas: while the chip is being made, a long wire that so far ends only
# at gates collects charge from the etching and can break them. Diodes give
# the charge a way out (sky130_fd_sc_hd__diode_2, on the do-not-synthesise
# list and therefore kept from every other step). Without this, the routed
# chip had 779 nets over the limits (signoff.py, antenna).
unset_dont_use sky130_fd_sc_hd__diode_2
# Its own rerouting allows the overflows that global routing above allows.
repair_antennas sky130_fd_sc_hd__diode_2 -iterations 5 -allow_congestion
set_dont_use sky130_fd_sc_hd__diode_2
check_placement

detailed_route -output_drc [file join $out drc.rpt] -verbose 1
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
# What the tools saw through the timing models; the numbers that count come
# from sta_flat.tcl.
set mpins [get_pins -of_objects [get_cells -filter "ref_name == $mcell"]]
set mclk {}
set min  {}
foreach p $mpins {
    set name [get_property $p lib_pin_name]
    if {$name eq "clk"} { lappend mclk $p } elseif {[get_property $p direction] eq "input"} { lappend min $p }
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
check_power_grid -net VPWR -dont_require_terminals
check_power_grid -net VGND -dont_require_terminals
puts "SECTION end"
puts "elapsed [expr {[clock seconds] - $t0}] s"

write_def     [file join $out $top.def]
write_db      [file join $out $top.odb]
write_verilog [file join $out $top.pnr.v]
