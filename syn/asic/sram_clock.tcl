# ------------------------------------------------------------------------------
# SRAM clock of the chip (pnr_top.tcl): earlier than the registers.
#
# Clock tree synthesis puts the SRAM clock pins in a tree of their own and
# lines it up with the register tree by delay buffers
# (delaybuf_*, at its root or further down). For the SRAMs that is the wrong
# target: their read data comes after the falling clock edge (half a cycle for
# the paths out of them), while the paths into them have a full cycle.
# sram_clock_early takes delay buffers out, on every path to an SRAM clock pin
# the one nearest to the port, a round at a time, until the SRAM clock pins
# get the clock `early` ns (slow corner) before the registers around the
# array, or none are left.
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

# Whether everything below instance b in the clock tree is an SRAM clock pin
# (through buffers only).
proc sram_clock_only_srams {b} {
    set out [[$b findITerm X] getNet]
    foreach it [$out getITerms] {
        set inst [$it getInst]
        if {$inst eq $b} continue
        set m [[$inst getMaster] getName]
        if {[string match sky130_sram_* $m]} continue
        if {[string match sky130_fd_sc_hd__clkbuf_* $m] && [sram_clock_only_srams $inst]} continue
        return 0
    }
    return 1
}

# The delay buffers that clock tree synthesis put in front of the SRAM clock
# pins to balance latency (delaybuf_*), anywhere in the tree: for every SRAM
# clock pin, the one nearest to the clock port on its way up, if nothing but
# SRAM clock pins lies below it (the clock gate and the registers keep theirs).
proc sram_clock_delaybufs {} {
    set found [dict create]
    foreach inst [$::block getInsts] {
        if {![string match sky130_sram_* [[$inst getMaster] getName]]} continue
        foreach pn {clk0 clk1} {
            set net [[$inst findITerm $pn] getNet]
            set top ""
            while {$net ne "NULL"} {
                set drv ""
                foreach it [$net getITerms] { if {[$it isOutputSignal]} { set drv [$it getInst] } }
                if {$drv eq ""} break
                if {[string match delaybuf_* [$drv getName]] && [sram_clock_only_srams $drv]} { set top $drv }
                set net [[$drv findITerm A] getNet]
            }
            if {$top ne ""} { dict set found [$top getName] $top }
        }
    }
    return [dict values $found]
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
        set bufs [sram_clock_delaybufs]
        if {[llength $bufs] == 0} { puts "sram_clock_early: no delay buffer left"; break }
        foreach b $bufs { sram_clock_bypass $b }
        estimate_parasitics -placement
        incr k [llength $bufs]
    }
    return $k
}
