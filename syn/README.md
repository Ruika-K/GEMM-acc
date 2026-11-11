# Synthesis

An ASIC flow (standard cells, SkyWater sky130) and two FPGA flows.

## ASIC: sky130 logic synthesis and pre-layout timing

`asic/run.py` maps the design to `sky130_fd_sc_hd` standard cells with Yosys
and analyses timing with OpenSTA at the typical (tt, 25 C, 1.80 V) and the slow
(ss, 100 C, 1.60 V) corner.

| Job | What is built |
|-----|---------------|
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

Results go to `syn/asic/results.csv`; netlists, timing reports and an area
breakdown per module (`breakdown.txt`) to `syn/build/asic/<job>/`. These are pre-layout numbers: no wires, no clock tree.
The operand memories are SRAM macros in an ASIC and are left out as black
boxes (`asic/gemm_mem_blackbox.sv`).

Gate-level simulation of a synthesised array with the RTL testbench and the
sky130 cell models:

```bash
python3 syn/asic/gls.py sys_8
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
product register and accumulator chain per PE, but operands and control are
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
