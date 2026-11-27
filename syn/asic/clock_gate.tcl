# ------------------------------------------------------------------------------
# The clock gate of the core datapath in the chip (pnr_top.tcl, CLOCK_GATING).
#
# Left to itself, clock tree synthesis puts the clock pin of the gate into
# the tree of the SRAM clock pins and balances everything through it: the
# SRAMs ended up 1.6 ns apart and the registers behind the gate 0.4 ns from
# the PEs. Here the gate is taken out instead, like the PE tree:
#
#   cg_detach     before clock tree synthesis: the gate's clock pin on a net
#                 of its own; returns the net behind the gate, which the
#                 synthesis is then given as a clock root of its own.
#   cg_connect    after it: the gate driven from the clock port, and delay
#                 buffers in front of the gate or in front of the root of the
#                 tree of the other registers, until the registers behind the
#                 gate and the controller and sequencer, which talk to them,
#                 get the clock together (slow corner).
#   ctree_root, ctree_pad   used here and by sram_clock.tcl.
# ------------------------------------------------------------------------------

proc cg_find {} {
    foreach inst [$::block getInsts] {
        if {[string match sky130_fd_sc_hd__dlclkp_* [[$inst getMaster] getName]]} { return $inst }
    }
    return ""
}

proc cg_detach {} {
    set icg [cg_find]
    set it [$icg findITerm CLK]
    set ::cg_port_net [$it getNet]
    $it disconnect
    set n [odb::dbNet_create $::block cg_cnet_in]
    $n setSigType CLOCK
    $it connect $n
    return [[[$icg findITerm GCLK] getNet] getName]
}

# The first buffer below the clock port on the way to iterm `it`.
proc ctree_root {it} {
    set net [$it getNet]
    set inst ""
    while {$net ne "NULL" && [llength [$net getBTerms]] == 0} {
        set drv ""
        foreach i [$net getITerms] { if {[$i isOutputSignal]} { set drv [$i getInst] } }
        if {$drv eq ""} break
        set inst $drv
        set net [[$drv findITerm [expr {[$drv findITerm A] ne "NULL" ? "A" : "CLK"}]] getNet]
    }
    return $inst
}

# One more buffer in front of instance b (between b and what drives it), at
# b's place. Returns the new buffer.
proc ctree_pad {b name} {
    set pin [expr {[$b findITerm A] ne "NULL" ? "A" : "CLK"}]
    set it [$b findITerm $pin]
    set net [$it getNet]
    $it disconnect
    set n [odb::dbNet_create $::block ${name}_net]
    $n setSigType CLOCK
    set p [odb::dbInst_create $::block [$::db findMaster sky130_fd_sc_hd__clkbuf_8] $name]
    [$p findITerm A] connect $net
    [$p findITerm X] connect $n
    $it connect $n
    set loc [$b getLocation]
    $p setLocation [lindex $loc 0] [lindex $loc 1]
    $p setPlacementStatus PLACED
    return $p
}

proc cg_median {pattern} {
    set v {}
    foreach p [get_pins -hierarchical $pattern] { lappend v [get_property $p arrival_max_rise] }
    set v [lsort -real $v]
    return [lindex $v [expr {[llength $v] / 2}]]
}

proc cg_connect {} {
    set icg [cg_find]
    set bb [$icg getBBox]
    set drv [odb::dbInst_create $::block [$::db findMaster sky130_fd_sc_hd__clkbuf_16] cg_ctree_drv]
    $drv setLocation [$bb xMin] [$bb yMin]
    $drv setPlacementStatus PLACED
    [$drv findITerm A] connect $::cg_port_net
    [$drv findITerm X] connect [[$icg findITerm CLK] getNet]
    detailed_placement
    estimate_parasitics -placement
    # A flip-flop of the ungated register tree, to find that tree's root.
    set ref [lindex [get_pins -hierarchical u_core/u_ctrl/*/CLK] 0]
    set ref_it [[ord::get_db_block] findITerm [get_full_name $ref]]
    set k 0
    while {$k < 16} {
        report_checks -corner ss -path_delay max -format end -group_path_count 1 > /dev/null
        set gated [cg_median u_core/g_*_skew*/*/CLK]
        set free  [cg_median {u_core/u_ctrl/*/CLK u_seq/*/CLK}]
        set gap [expr {$gated - $free}]
        puts [format "cg_connect: %d delay buffers, behind the gate %.3f, controller and sequencer %.3f, difference %.3f" \
            $k $gated $free $gap]
        if {abs($gap) < 0.15} break
        if {$gap > 0} {
            ctree_pad [ctree_root $ref_it] cg_free_dly_$k
        } else {
            ctree_pad $drv cg_gate_dly_$k
        }
        detailed_placement
        estimate_parasitics -placement
        incr k
    }
}
