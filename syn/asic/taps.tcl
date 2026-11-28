# ------------------------------------------------------------------------------
# A well tap for every n-well (pnr_top.tcl, pnr_hier.tcl).
#
# The n-well of the standard cells reaches the supply only through tap cells
# (sky130_fd_sc_hd__tapvpwrvgnd_1). Rows alternate in orientation, and a row
# and its flipped neighbour share one n-well (an N row has it in its upper
# half, the FS row above it in its lower half), so one tap serves both pieces
# of a pair. tapcell places taps at a fixed distance, offset by half of it in
# every other row; a pair of pieces of row shorter than that, cut out by the
# macros, can end up without one, and its n-well floats. In the chip that was
# every pair in the channels between PE columns (9.2 um long); LVS found them
# as n-well islands. This adds a tap at the start of the N piece of every
# pair that has none. The FS piece stays free for the 9.2 um wide clock
# buffers of the PE clock tree.
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
    # Pieces of row by their extent: "x1 x2 y" -> row.
    set pieces [dict create]
    foreach row [$block getRows] {
        set bb [$row getBBox]
        dict set pieces "[$bb xMin] [$bb xMax] [$bb yMin]" $row
    }
    proc has_tap {taps x1 x2 y} {
        if {![dict exists $taps $y]} { return 0 }
        foreach x [dict get $taps $y] { if {$x >= $x1 && $x < $x2} { return 1 } }
        return 0
    }
    set n 0
    dict for {key row} $pieces {
        lassign $key x1 x2 y
        if {$x2 - $x1 < $width || [$row getOrient] ne "R0"} continue
        # The FS piece above shares the n-well, if it covers the same extent.
        set h [expr {[[$row getBBox] yMax] - $y}]
        set above "$x1 $x2 [expr {$y + $h}]"
        if {[has_tap $taps $x1 $x2 $y]} continue
        if {[dict exists $pieces $above] && [has_tap $taps $x1 $x2 [expr {$y + $h}]]} continue
        set t [odb::dbInst_create $block $master "TAP_ROW_PIECE_$n"]
        $t setOrient R0
        $t setLocation $x1 $y
        $t setPlacementStatus FIRM
        incr n
    }
    # FS pieces without an N piece below them that has a tap.
    dict for {key row} $pieces {
        lassign $key x1 x2 y
        if {$x2 - $x1 < $width || [$row getOrient] ne "MX"} continue
        set h [expr {[[$row getBBox] yMax] - $y}]
        set below "$x1 $x2 [expr {$y - $h}]"
        if {[has_tap $taps $x1 $x2 $y]} continue
        if {[dict exists $pieces $below]} continue          ;# served by the N piece below
        set t [odb::dbInst_create $block $master "TAP_ROW_PIECE_$n"]
        $t setOrient MX
        $t setLocation $x1 $y
        $t setPlacementStatus FIRM
        incr n
    }
    puts "tap_every_row: $n taps added for n-wells without one"
    return $n
}
