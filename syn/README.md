# Synthesis

An ASIC flow (standard cells, SkyWater sky130) and two FPGA flows.

## ASIC: sky130 synthesis, place and route

`asic/run.py` maps the design to `sky130_fd_sc_hd` standard cells with Yosys
and analyses timing with OpenSTA at the typical (tt, 25 C, 1.80 V) and the slow
(ss, 100 C, 1.60 V) corner.

| Job | What is built |
|-----|---------------|
| `mac`, `mac_nopipe`, `mac_ripple` | the multiply-accumulate datapath of a PE (`gemm_mac`) |
| `pe`, `pe_nopipe` | one processing element |
| `sys_N` | `N x N` systolic array |
| `bcast_N` | `N x N` broadcast baseline |
| `sys_8_ripple` | 8 x 8 systolic array with a ripple-carry accumulator adder |
| `sys_8_nopipe` | 8 x 8 systolic array without the product register |
| `core_8` | `gemm_core`: array, skew lines, controller, output FIFO |
| `top_8` | complete accelerator, operand memories as black boxes |

Tools: Yosys 0.40 or newer and OpenSTA (the `sta` binary, also part of
OpenROAD) on `PATH`. With nix:

```bash
nix shell nixpkgs#yosys nixpkgs#openroad
```

PDK: the `common` and `sky130_fd_sc_hd` archives of an open_pdks build,
unpacked so that `$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib` exists.
`PDK_ROOT` defaults to `~/pdk/sky130`.

```bash
python3 syn/asic/run.py
```

Synthesis is bottom-up for `gemm_mac`: it is mapped once per variant and that
netlist is placed into every design that contains it, so that all arrays,
systolic and broadcast, are built from the same gates.

Results go to `syn/asic/results.csv`; netlists, timing reports and an area
breakdown per module (`breakdown.txt`) to `syn/build/asic/<job>/`. These are
pre-layout numbers: no wires, no clock tree.
The operand memories are SRAM macros in an ASIC and are left out as black
boxes (`asic/gemm_mem_blackbox.sv`).

Gate-level simulation of a synthesised array with the RTL testbench and the
sky130 cell models:

```bash
python3 syn/asic/gls.py sys_8
```

Place and route with OpenROAD, on the netlists the synthesis step left behind:

```bash
python3 syn/asic/pnr.py pe sys_4 bcast_4
python3 syn/asic/pnr.py --parse sys_4      # re-read the log of an earlier run
```

`asic/pnr.tcl` is the flow itself: floorplan, power grid, placement, clock
tree synthesis, setup and hold repair, global and detailed routing, parasitic
extraction, then timing at the typical, slow and fast corner with the extracted
wires. Pins are placed on the side their data flows through (A on the west
edge, B on the north edge, the shift chain south to north). Results go to
`syn/asic/pnr_results.csv`, the layout (DEF, ODB), the SPEF and the log to
`syn/build/asic/<design>/pnr/` (`pnr_est/` for the reduced flow).

| Job | Flow |
|-----|------|
| `pe`, `sys_4`, `bcast_4`, `sys_8`, `bcast_8` | full: timing-driven placement, detailed routing, extracted parasitics |
| `sys_8_est`, `bcast_8_est`, `sys_16_est`, `bcast_16_est` | reduced: placement for wire length, global routing, wire estimates |

The 16 x 16 arrays are about 160 000 cells. Timing-driven placement and
detailed routing of a block that size each take hours on a four-core machine,
so they go through the reduced flow, and the 8 x 8 arrays are run through
both to show how the two flows compare. A full 8 x 8 run takes about 50
minutes, a reduced 16 x 16 run about 10.

Two things in this flow are there because of how OpenROAD (26Q3) behaves when
it cannot close timing:

* Place and route uses its own clock period (`PERIOD` in `pnr.py`, 10 ns), not
  the 5 ns of synthesis. Timing is repaired for all corners at once, and at the
  slow corner 5 ns is out of reach by a factor of two. 10 ns is missed by
  10 - 20 %, so the result is what the tools reach when pushed.
* Setup repair runs with `-skip_buffering`. With buffer insertion enabled it
  left chains of up to 50 single-fanout buffers on paths it could not close,
  and after routing those chains were the critical path. `pnr.py` checks for
  this: `crit_path_bufs` is the number of buffers on the worst path and
  `buf_chain` the longest single-fanout buffer chain in the routed netlist.

Gate-level simulation of a routed array (clock tree and hold buffers included):

```bash
python3 syn/asic/gls.py --pnr sys_4
```

## FPGA

Two flows that implement the same jobs.

| Job        | What is built |
|------------|---------------|
| `sys_N`    | `N x N` systolic array (`rtl/gemm_array.sv`) inside the harness |
| `bcast_N`  | `N x N` broadcast baseline (`common/gemm_array_bcast.sv`) inside the same harness |
| `*_nopipe` | the same with `PE_PIPE = 0` |
| `*_lut`    | the same with multipliers built from LUTs (ECP5 flow only) |
| `*_dsp`    | the same with DSP blocks forced by `GEMM_USE_DSP` (Vivado flow only) |
| `top_8`    | the complete accelerator with an 8 x 8 array |

`common/syn_array_harness.sv` feeds all array inputs from a serial shift
register and captures all outputs into another one. An array has far more port
bits than a device has pins; with the harness every array path is register to
register and the wrapper itself is one LUT deep.

`common/gemm_array_bcast.sv` is the comparison point: the same multiply,
product register, accumulator and shift chain per PE, but operands and control are
registered once at the edge and broadcast instead of being forwarded from PE to
PE. It is checked against numpy by `tb/test_gemm_array_bcast.py`.

### Vivado

Status: the `quick` mode has been run with Vivado 2023.2 (three jobs, no
errors). The script was changed afterwards (clock constraints, utilisation
taken from the report, job list); the `standard` sweep has not been run yet.

Vivado builds the 8 x 8 bit multipliers from LUTs by default, so the jobs are
not limited by the number of DSP blocks. The `_dsp` jobs define `GEMM_USE_DSP`,
which puts `(* use_dsp = "yes" *)` on the PE; that costs two DSP blocks per PE.

```bash
vivado -mode batch -source syn/vivado/run.tcl
```

Optional arguments after `-tclargs`: mode (`quick`, `standard`, `full`), part
(default `xc7z020clg400-1`), clock period in ns for the LUT-multiplier jobs
(default `6.0`) and for the DSP jobs (default `3.5`). For example a three-job
smoke test:

```bash
vivado -mode batch -source syn/vivado/run.tcl -tclargs quick
```

Everything is implemented out of context, so only register-to-register paths
are timed. One line per job is appended to `syn/vivado/results.csv`; the timing
and utilisation reports are in `syn/build/vivado/<job>/`.

### ECP5 (open source)

Needs `yosys` and `nextpnr-ecp5` from the distribution and a recent Yosys from
PyPI as SystemVerilog front end:

```bash
pip install -r syn/requirements.txt
```

```bash
python3 syn/ecp5/run.py
```

`python3 syn/ecp5/run.py --list` shows the job names; pass names to run a
subset. Results go to `syn/ecp5/results.csv`.
