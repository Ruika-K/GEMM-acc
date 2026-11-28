# ------------------------------------------------------------------------------
# A well tap in every piece of row (pnr_top.tcl, pnr_hier.tcl).
#
# The n-well of the standard cells reaches the supply only through tap cells
# (sky130_fd_sc_hd__tapvpwrvgnd_1). tapcell places them at a fixed distance,
# offset by half of it in every other row; a piece of row shorter than that,
# cut out by the macros, can end up without one, and the n-well of its cells
# floats. In the chip that was every row in the channels between PE columns
# (9.2 um long, 2576 pieces); LVS found them as n-well islands. This adds a
# tap at the start of every piece that has none.
# ------------------------------------------------------------------------------

proc tap_every_row {} {
    set block [ord::get_db_block]
    set master [[ord::get_db] findMaster sky130_fd_sc_hd__tapvpwrvgnd_1]
    set width [$master getWidth]
    set taps [dict create]
    foreach inst [$block getInsts] {
        if {[$inst getMaster] eq $master} {
            lassign [$inst getLocation] x y
            dict lappend taps $y $x
        }
    }
    set n 0
    foreach row [$block getRows] {
        set bb [$row getBBox]
        set x1 [$bb xMin]; set x2 [$bb xMax]; set y [$bb yMin]
        if {$x2 - $x1 < $width} continue
        set found 0
        if {[dict exists $taps $y]} {
            foreach x [dict get $taps $y] { if {$x >= $x1 && $x < $x2} { set found 1; break } }
        }
        if {$found} continue
        set t [odb::dbInst_create $block $master "TAP_ROW_PIECE_$n"]
        $t setOrient [$row getOrient]
        $t setLocation $x1 $y
        $t setPlacementStatus FIRM
        incr n
    }
    puts "tap_every_row: $n taps added in pieces of row without one"
    return $n
}
