# ------------------------------------------------------------------------------
# Vivado synthesis and implementation sweep (non-project, out-of-context).
#
#   vivado -mode batch -source syn/vivado/run.tcl
#   vivado -mode batch -source syn/vivado/run.tcl -tclargs quick
#   vivado -mode batch -source syn/vivado/run.tcl -tclargs full xc7a200tfbg676-2 3.0
#
# Arguments (all optional, in this order):
#   mode    quick | standard | full       which jobs to run, default standard
#   part    device, default xc7z020clg400-1
#   period  clock constraint in ns, default 3.0
#
# Jobs:
#   sys_N    N x N systolic array inside the synthesis harness
#   bcast_N  N x N broadcast baseline inside the same harness
#   top_8    the complete accelerator, 8 x 8 array
#
#   quick    sys_8, bcast_8, top_8
#   standard N = 4, 8, 12, 14 (14 x 14 = 196 multipliers, fits the 220 DSP48E1
#            of an xc7z020), plus the 8 x 8 arrays without product register,
#            plus top_8
#   full     standard plus N = 16, 24 (needs a larger part, e.g. xc7a200t)
#
# Output:
#   syn/build/vivado/<job>/   timing and utilisation reports, run log
#   syn/vivado/results.csv    one line per job
#
# Fmax is reported as 1000 / (period - WNS). Designs are implemented out of
# context: only register-to-register paths are timed, ports are unconstrained.
# ------------------------------------------------------------------------------

set ROOT [file normalize [file join [file dirname [info script]] .. ..]]

set MODE   "standard"
set PART   "xc7z020clg400-1"
set PERIOD 3.0
if {[llength $argv] > 0} { set MODE   [lindex $argv 0] }
if {[llength $argv] > 1} { set PART   [lindex $argv 1] }
if {[llength $argv] > 2} { set PERIOD [lindex $argv 2] }

set RTL_FILES   [lsort [glob [file join $ROOT rtl *.sv]]]
set ARRAY_FILES [concat \
    [list [file join $ROOT rtl gemm_pe.sv] [file join $ROOT rtl gemm_array.sv]] \
    [lsort [glob [file join $ROOT syn common *.sv]]]]

set BUILD   [file join $ROOT syn build vivado]
set RESULTS [file join $ROOT syn vivado results.csv]

# ------------------------------------------------------------------------------
# Job list: name, top, clock port, sources, generics
# ------------------------------------------------------------------------------
proc array_job {name bcast n pipe} {
    global ARRAY_FILES
    return [list $name syn_array_harness clk $ARRAY_FILES \
        [list BCAST=$bcast ROWS=$n COLS=$n PE_PIPE=$pipe]]
}

set JOBS {}
switch -- $MODE {
    quick    { set SIZES {8} }
    standard { set SIZES {4 8 12 14} }
    full     { set SIZES {4 8 12 14 16 24} }
    default  { error "unknown mode '$MODE' (quick | standard | full)" }
}
foreach n $SIZES {
    lappend JOBS [array_job sys_$n   0 $n 1]
    lappend JOBS [array_job bcast_$n 1 $n 1]
}
if {$MODE ne "quick"} {
    lappend JOBS [array_job sys_8_nopipe   0 8 0]
    lappend JOBS [array_job bcast_8_nopipe 1 8 0]
}
lappend JOBS [list top_8 gemm_top aclk $RTL_FILES [list ROWS=8 COLS=8 PE_PIPE=1]]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
proc count_cells {filter} {
    return [llength [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && ($filter)"]]
}

proc run_job {job} {
    global PART PERIOD BUILD
    lassign $job name top clk files generics

    set dir [file join $BUILD $name]
    file mkdir $dir

    create_project -in_memory -part $PART
    read_verilog -sv $files

    set cmd [list synth_design -top $top -part $PART -mode out_of_context \
        -verilog_define SYNTHESIS=1]
    foreach g $generics { lappend cmd -generic $g }
    {*}$cmd

    create_clock -name clk -period $PERIOD [get_ports $clk]
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
    set fmax [format %.1f [expr {1000.0 / ($PERIOD - $wns)}]]

    set lut    [count_cells {REF_NAME =~ LUT*}]
    set ff     [count_cells {REF_NAME =~ FD*}]
    set srl    [count_cells {REF_NAME =~ SRL*}]
    set dsp    [count_cells {REF_NAME =~ DSP48*}]
    set bram   [count_cells {REF_NAME =~ RAMB*}]
    set lutram [count_cells {REF_NAME =~ RAM* && REF_NAME !~ RAMB*}]
    # How many DSP blocks use their internal multiplier / output registers.
    set dsp_mreg [count_cells {REF_NAME =~ DSP48* && MREG == 1}]
    set dsp_preg [count_cells {REF_NAME =~ DSP48* && PREG == 1}]

    close_project
    return [list $name $PART $PERIOD $wns $fmax $lut $ff $srl $dsp $dsp_mreg $dsp_preg \
        $bram $lutram]
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
file mkdir $BUILD
set header "job,part,period_ns,wns_ns,fmax_mhz,lut,ff,srl,dsp,dsp_mreg,dsp_preg,bram,lutram"
if {![file exists $RESULTS]} {
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
