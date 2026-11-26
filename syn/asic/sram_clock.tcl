# ------------------------------------------------------------------------------
# SRAM clock of the chip (pnr_top.tcl): earlier than the registers.
#
# Clock tree synthesis puts the SRAM clock pins in a tree of their own and
# lines it up with the register tree by a chain of delay buffers at its root
# (delaybuf_*). For the SRAMs that is the wrong target: their read data comes
# after the falling clock edge (half a cycle for the paths out of them), while
# the paths into them have a full cycle. sram_clock_early takes delay buffers
# out of that chain, one at a time, until the SRAM clock pins get the clock
# `early` ns (slow corner) before the registers around the array, or the chain
# is empty.
# ------------------------------------------------------------------------------

proc sram_clock_median {} {
    report_checks -corner ss -path_delay max -format end -group_path_count 1 > /dev/null
    set v {}
    foreach c [get_cells -filter "ref_name =~ sky130_sram_*"] {
        foreach pn {clk0 clk1} { lappend v [get_property [get_pins [get_full_name $c]/$pn] arrival_max_rise] }
    }
    set reg {}
    foreach p [get_pins -hierarchical u_core/g_*_skew*/*/CLK] { lappend reg [get_property $p arrival_max_rise] }
    set v [lsort -real $v]; set reg [lsort -real $reg]
    return [list [lindex $v [expr {[llength $v] / 2}]] [lindex $reg [expr {[llength $reg] / 2}]] \
        [lindex $v 0] [lindex $v end]]
}

# The delay buffers in front of the SRAM clock pins: walk from one SRAM clock
# pin towards the clock port and keep the buffers that CTS inserted to balance
# latency, nearest to the port first.
proc sram_clock_delaybufs {} {
    set sram {}
    foreach inst [$::block getInsts] {
        if {[string match sky130_sram_* [[$inst getMaster] getName]]} { set sram $inst; break }
    }
    if {$sram eq ""} { return {} }
    set net [[$sram findITerm clk0] getNet]
    set chain {}
    while {$net ne "NULL"} {
        set drv ""
        foreach it [$net getITerms] { if {[$it isOutputSignal]} { set drv [$it getInst] } }
        if {$drv eq ""} break
        if {[string match delaybuf_* [$drv getName]]} { set chain [linsert $chain 0 $drv] }
        set net [[$drv findITerm A] getNet]
    }
    return $chain
}

# Take buffer b out: its loads move to its input net.
proc sram_clock_bypass {b} {
    set in  [[$b findITerm A] getNet]
    set out [[$b findITerm X] getNet]
    foreach it [$out getITerms] {
        if {[$it getInst] ne $b} { $it disconnect; $it connect $in }
    }
    odb::dbInst_destroy $b
    odb::dbNet_destroy $out
}

proc sram_clock_early {early} {
    set k 0
    while 1 {
        lassign [sram_clock_median] sram reg lo hi
        set excess [expr {$sram - ($reg - $early)}]
        puts [format "sram_clock_early: %d delay buffers removed, SRAM clock pins %.3f (%.3f .. %.3f), registers %.3f - %.2f, excess %.3f" \
            $k $sram $lo $hi $reg $early $excess]
        # A delay buffer is 0.3 - 0.4 ns: take one out while that brings the
        # pins closer to the target.
        if {$excess < 0.18} break
        set chain [sram_clock_delaybufs]
        if {[llength $chain] == 0} { puts "sram_clock_early: no delay buffer left"; break }
        sram_clock_bypass [lindex $chain 0]
        estimate_parasitics -placement
        incr k
    }
    return $k
}
