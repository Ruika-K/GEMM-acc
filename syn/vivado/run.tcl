# ------------------------------------------------------------------------------
# Vivado synthesis and implementation sweep (non-project, out-of-context).
#
#   vivado -mode batch -source syn/vivado/run.tcl
#   vivado -mode batch -source syn/vivado/run.tcl -tclargs quick
#   vivado -mode batch -source syn/vivado/run.tcl -tclargs full xc7a200tfbg676-2
#
# Arguments (all optional, in this order):
#   mode        quick | standard | full   which jobs to run, default standard
#   part        device, default xc7z020clg400-1
#   period      clock constraint in ns for LUT-multiplier jobs, default 6.0
#   period_dsp  clock constraint in ns for DSP jobs, default 3.5
#
# Jobs:
#   sys_N        N x N systolic array inside the synthesis harness
#   bcast_N      N x N broadcast baseline inside the same harness
#   *_nopipe     the same without the product register (PE_PIPE = 0)
#   *_dsp        the same with (* use_dsp = "yes" *) on the PE
#   top_8        the complete accelerator, 8 x 8 array
#
#   quick     sys_8, bcast_8, top_8
#   standard  N = 4, 8, 12, 16, plus the 8 x 8 variants (_nopipe, _dsp), plus
#             top_8
#   full      standard plus N = 24 (needs a larger part, e.g. xc7a200t)
#
# By default Vivado builds the 8 x 8 bit multipliers from LUTs, so the array
# size is limited by LUTs and not by the number of DSP blocks. The _dsp jobs
# force DSP blocks (two per PE: multiplier and accumulator) for comparison.
#
# Output:
#   syn/build/vivado/<job>/   timing and utilisation reports
#   syn/vivado/results.csv    one line per job
#
# Fmax is reported as 1000 / (period - WNS). When WNS is positive this is a
# lower bound: the tools stop optimising once the constraint is met. Designs
# are implemented out of context: only register-to-register paths are timed.
# ------------------------------------------------------------------------------

set ROOT [file normalize [file join [file dirname [info script]] .. ..]]

set MODE       "standard"
set PART       "xc7z020clg400-1"
set PERIOD     6.0
set PERIOD_DSP 3.5
if {[llength $argv] > 0} { set MODE       [lindex $argv 0] }
if {[llength $argv] > 1} { set PART       [lindex $argv 1] }
if {[llength $argv] > 2} { set PERIOD     [lindex $argv 2] }
if {[llength $argv] > 3} { set PERIOD_DSP [lindex $argv 3] }

set RTL_FILES   [lsort [glob [file join $ROOT rtl *.sv]]]
set ARRAY_FILES [concat \
    [list [file join $ROOT rtl gemm_mac.sv] [file join $ROOT rtl gemm_pe.sv] [file join $ROOT rtl gemm_array.sv]] \
    [lsort [glob [file join $ROOT syn common *.sv]]]]

set BUILD   [file join $ROOT syn build vivado]
set RESULTS [file join $ROOT syn vivado results.csv]

# ------------------------------------------------------------------------------
# Job list: name, top, clock port, sources, generics, defines, period
# ------------------------------------------------------------------------------
proc array_job {name bcast n pipe {dsp 0}} {
    global ARRAY_FILES PERIOD PERIOD_DSP
    set defines {SYNTHESIS=1}
    set period  $PERIOD
    if {$dsp} {
        lappend defines GEMM_USE_DSP=1
        set period $PERIOD_DSP
    }
    return [list $name syn_array_harness clk $ARRAY_FILES \
        [list BCAST=$bcast ROWS=$n COLS=$n PE_PIPE=$pipe] $defines $period]
}

set JOBS {}
switch -- $MODE {
    quick    { set SIZES {8} }
    standard { set SIZES {4 8 12 16} }
    full     { set SIZES {4 8 12 16 24} }
    default  { error "unknown mode '$MODE' (quick | standard | full)" }
}
foreach n $SIZES {
    lappend JOBS [array_job sys_$n   0 $n 1]
    lappend JOBS [array_job bcast_$n 1 $n 1]
}
if {$MODE ne "quick"} {
    lappend JOBS [array_job sys_8_nopipe   0 8 0]
    lappend JOBS [array_job bcast_8_nopipe 1 8 0]
    lappend JOBS [array_job sys_8_dsp      0 8 1 1]
    lappend JOBS [array_job bcast_8_dsp    1 8 1 1]
}
lappend JOBS [list top_8 gemm_top aclk $RTL_FILES [list ROWS=8 COLS=8 PE_PIPE=1] \
    {SYNTHESIS=1} $PERIOD]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
proc count_cells {filter} {
    return [llength [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && ($filter)"]]
}

# "Used" column of a row of the utilisation report, e.g.
#   | Slice LUTs                 | 6220 |     0 | ...
# Returns $fallback when the row is not found (the row names differ between
# device families and may change between Vivado versions).
proc util_value {report label fallback} {
    set pattern [format {^\|\s*%s\*?\s*\|\s*([0-9.]+)} $label]
    if {[regexp -line -- $pattern $report -> value]} { return $value }
    return $fallback
}

proc run_job {job} {
    global PART BUILD
    lassign $job name top clk files generics defines period

    set dir [file join $BUILD $name]
    file mkdir $dir

    create_project -in_memory -part $PART
    read_verilog -sv $files

    set cmd [list synth_design -top $top -part $PART -mode out_of_context]
    foreach d $defines  { lappend cmd -verilog_define $d }
    foreach g $generics { lappend cmd -generic $g }
    {*}$cmd

    create_clock -name clk -period $period [get_ports $clk]
    # Tell the out-of-context flow that the clock arrives through a global buffer.
    catch { set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports $clk] }

    opt_design
    place_design
    phys_opt_design
    route_design

    report_timing_summary -file [file join $dir timing_summary.rpt]
    report_timing -setup -max_paths 5 -file [file join $dir timing_worst_paths.rpt]
    report_utilization -file [file join $dir utilization.rpt]
    report_utilization -hierarchical -file [file join $dir utilization_hier.rpt]

    set wns  [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
    set fmax [format %.1f [expr {1000.0 / ($period - $wns)}]]

    # Physical resources from the utilisation report. Counting LUT cells
    # overstates the LUT usage, because two small LUTs can share one LUT6.
    set rpt    [report_utilization -return_string]
    set lut    [util_value $rpt {(?:Slice|CLB) LUTs}        [count_cells {REF_NAME =~ LUT*}]]
    set ff     [util_value $rpt {(?:Slice|CLB) Registers}   [count_cells {REF_NAME =~ FD*}]]
    set srl    [util_value $rpt {LUT as Shift Register}     [count_cells {REF_NAME =~ SRL*}]]
    set lutram [util_value $rpt {LUT as Distributed RAM} \
        [count_cells {REF_NAME =~ RAM* && REF_NAME !~ RAMB*}]]
    set bram   [util_value $rpt {Block RAM Tile}            [count_cells {REF_NAME =~ RAMB*}]]
    set dsp    [util_value $rpt {DSPs}                      [count_cells {REF_NAME =~ DSP48*}]]
    # How many DSP blocks use their internal multiplier / output registers.
    set dsp_mreg [count_cells {REF_NAME =~ DSP48* && MREG == 1}]
    set dsp_preg [count_cells {REF_NAME =~ DSP48* && PREG == 1}]

    close_project
    return [list $name $PART $period $wns $fmax $lut $ff $srl $lutram $bram $dsp \
        $dsp_mreg $dsp_preg]
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
file mkdir $BUILD
set header "job,part,period_ns,wns_ns,fmax_mhz,lut,ff,srl,lutram,bram,dsp,dsp_mreg,dsp_preg"

# Start a new results file if there is none or if an older run used other columns.
set fresh 1
if {[file exists $RESULTS]} {
    set f [open $RESULTS r]
    gets $f first
    close $f
    if {$first eq $header} {
        set fresh 0
    } else {
        file rename -force $RESULTS [file join [file dirname $RESULTS] results.prev.csv]
    }
}
if {$fresh} {
    set f [open $RESULTS w]
    puts $f $header
    close $f
}

set summary {}
foreach job $JOBS {
    set name [lindex $job 0]
    puts "=== $name ==="
    if {[catch {run_job $job} row]} {
        puts "!!! $name failed: $row"
        catch { close_project }
        lappend summary "$name: FAILED ($row)"
        continue
    }
    set f [open $RESULTS a]
    puts $f [join $row ,]
    close $f
    lappend summary [join $row ,]
}

puts ""
puts $header
foreach line $summary { puts $line }
puts ""
puts "Reports: $BUILD"
puts "Results: $RESULTS"
