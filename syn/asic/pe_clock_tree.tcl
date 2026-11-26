# ------------------------------------------------------------------------------
# A clock tree built by hand for the PE array of the chip (pnr_top.tcl).
#
# The PEs sit on a regular grid, so an H-tree can give every PE the same path
# from the root: the same number of buffers and the same wire lengths. The
# clock tree synthesis of OpenROAD clusters the 64 PE clock pins into groups of
# about 15 and gives the groups different depths, which leaves steps of
# 0.2 - 0.3 ns between neighbouring PEs, and a PE passes its data to its
# neighbour in one cycle.
#
#   pe_htree_build       before clock tree synthesis: buffers in the channels
#                        between the PEs, PE clock pins moved onto them. The
#                        root is left unconnected, so the synthesis builds the
#                        trees of the registers and of the SRAMs only.
#   pe_htree_connect     after it: the root is driven from the clock port
#                        through a chain of buffers, lengthened until the
#                        flip-flops inside the PEs (pin arrival plus the clock
#                        tree inside the macro) see the clock when the
#                        registers that talk to the array do.
# ------------------------------------------------------------------------------

proc pe_htree_inst {cell row col} {
    return [$::block findInst "u_core/u_array/g_row\\\[$row\\\].g_col\\\[$col\\\].u_pe"]
}

proc pe_htree_buf {name master x y} {
    set m [$::db findMaster $master]
    set b [odb::dbInst_create $::block $m $name]
    $b setLocation [expr {round($x - [$m getWidth] / 2.0)}] [expr {round($y - [$m getHeight] / 2.0)}]
    $b setPlacementStatus PLACED
    return $b
}

# Nets are named apart from the buffers that drive them (pe_cnet_* and
# pe_ctree_*): in a SPEF file "name:12" is a node of net "name" or pin 12 of
# instance "name", and with both present OpenSTA drops the net's parasitics.
proc pe_htree_net {name} {
    set n [odb::dbNet_create $::block $name]
    $n setSigType CLOCK
    return $n
}

# Centre of the channel crossing between rows r-1, r and columns c-1, c (row 0
# is the top row).
proc pe_htree_point {cell r c} {
    set ul [[pe_htree_inst $cell [expr {$r - 1}] [expr {$c - 1}]] getBBox]
    set lr [[pe_htree_inst $cell $r $c] getBBox]
    return [list [expr {([$ul xMax] + [$lr xMin]) / 2.0}] [expr {([$ul yMin] + [$lr yMax]) / 2.0}]]
}

# One level of the tree over rows r0 .. r0+n-1 and columns c0 .. c0+n-1: a
# buffer at the centre, driving the four quadrants (or, at the last level, the
# four PEs).
proc pe_htree_level {cell r0 c0 n net_in} {
    set h [expr {$n / 2}]
    set leaf [expr {$n == 2}]
    lassign [pe_htree_point $cell [expr {$r0 + $h}] [expr {$c0 + $h}]] x y
    set name "pe_ctree_${n}_${r0}_${c0}"
    set b [pe_htree_buf $name [expr {$leaf ? "sky130_fd_sc_hd__clkbuf_8" : "sky130_fd_sc_hd__clkbuf_16"}] $x $y]
    [$b findITerm A] connect $net_in
    set out [pe_htree_net pe_cnet_${n}_${r0}_${c0}]
    [$b findITerm X] connect $out
    lappend ::pe_htree_nets [$out getName]
    foreach dr [list 0 $h] {
        foreach dc [list 0 $h] {
            if {$leaf} {
                set it [[pe_htree_inst $cell [expr {$r0 + $dr}] [expr {$c0 + $dc}]] findITerm clk]
                $it disconnect
                $it connect $out
            } else {
                pe_htree_level $cell [expr {$r0 + $dr}] [expr {$c0 + $dc}] $h $out
            }
        }
    }
    return $b
}

proc pe_htree_build {cell n} {
    if {$n < 2 || ($n & ($n - 1)) != 0} { error "pe_htree_build: $n x $n is not a power of two" }
    set ::pe_htree_nets {}
    set ::pe_htree_in [pe_htree_net pe_cnet_in]
    set root [pe_htree_level $cell 0 0 $n $::pe_htree_in]
    lappend ::pe_htree_nets pe_cnet_in
    puts "pe_htree_build: [llength $::pe_htree_nets] nets, root [$root getName]"
    return $root
}

# Clock arrival (slow corner, the corner of the last report_checks) at the PE
# clock pins and at the flip-flops of the skew and de-skew lines, which are
# what the PEs exchange data with.
proc pe_htree_median {l} { set l [lsort -real $l]; return [lindex $l [expr {[llength $l] / 2}]] }
proc pe_htree_arrivals {cell} {
    report_checks -corner ss -path_delay max -format end -group_path_count 1 > /dev/null
    set pe {}
    foreach c [get_cells -filter "ref_name == $cell"] { lappend pe [get_property [get_pins [get_full_name $c]/clk] arrival_max_rise] }
    set reg {}
    foreach p [get_pins -hierarchical u_core/g_*_skew*/*/CLK] { lappend reg [get_property $p arrival_max_rise] }
    return [list [pe_htree_median $pe] [pe_htree_median $reg] [tcl::mathfunc::min {*}$pe] [tcl::mathfunc::max {*}$pe]]
}

# internal: latency of the clock tree inside a PE at the slow corner (from its
# timing model, pnr.py passes it).
proc pe_htree_connect {cell clk_port internal} {
    set bt [$::block findBTerm $clk_port]
    set port_net [$bt getNet]
    set bb [$bt getBBox]
    set root_in [lindex [$::pe_htree_in getITerms] 0]
    set root [$root_in getInst]
    # A driver next to the clock port, the long wire to the centre of the
    # array, then the delay buffers next to the root.
    set drv [pe_htree_buf pe_ctree_drv sky130_fd_sc_hd__clkbuf_16 \
        [expr {([$bb xMin] + [$bb xMax]) / 2.0}] [expr {[$bb yMax] + 10000}]]
    [$drv findITerm A] connect $port_net
    [$drv findITerm X] connect $::pe_htree_in
    detailed_placement
    estimate_parasitics -placement
    set k 0
    while 1 {
        lassign [pe_htree_arrivals $cell] pe reg lo hi
        set gap [expr {$reg - $pe - $internal}]
        puts [format "pe_htree_connect: %d delay buffers, PE pins %.3f (%.3f .. %.3f) + %.2f inside, registers %.3f, gap %.3f" \
            $k $pe $lo $hi $internal $reg $gap]
        if {$gap < 0.08 || $k >= 16} break
        set it [$root findITerm A]
        set net [$it getNet]
        $it disconnect
        set n [pe_htree_net pe_cnet_dly_$k]
        set b [odb::dbInst_create $::block [$::db findMaster sky130_fd_sc_hd__clkbuf_8] pe_ctree_dly_$k]
        [$b findITerm A] connect $net
        [$b findITerm X] connect $n
        $it connect $n
        set loc [$root getLocation]
        $b setLocation [lindex $loc 0] [lindex $loc 1]
        $b setPlacementStatus PLACED
        set root $b
        detailed_placement
        estimate_parasitics -placement
        incr k
    }
    return $k
}
