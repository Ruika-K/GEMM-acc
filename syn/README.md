# Synthesis

Two flows that implement the same jobs.

| Job        | What is built |
|------------|---------------|
| `sys_N`    | `N x N` systolic array (`rtl/gemm_array.sv`) inside the harness |
| `bcast_N`  | `N x N` broadcast baseline (`common/gemm_array_bcast.sv`) inside the same harness |
| `*_nopipe` | the same with `PE_PIPE = 0` |
| `*_lut`    | the same with multipliers built from LUTs (ECP5 flow only) |
| `top_8`    | the complete accelerator with an 8 x 8 array |

`common/syn_array_harness.sv` feeds all array inputs from a serial shift
register and captures all outputs into another one. An array has far more port
bits than a device has pins; with the harness every array path is register to
register and the wrapper itself is one LUT deep.

`common/gemm_array_bcast.sv` is the comparison point: the same multiply,
product register and accumulator chain per PE, but operands and control are
registered once at the edge and broadcast instead of being forwarded from PE to
PE. It is checked against numpy by `tb/test_gemm_array_bcast.py`.

## Vivado

Status: not run yet. The script has only been dry-run with stubbed commands.

```bash
vivado -mode batch -source syn/vivado/run.tcl
```

Optional arguments after `-tclargs`: mode (`quick`, `standard`, `full`), part
(default `xc7z020clg400-1`), clock period in ns (default `3.0`). For example a
three-job smoke test:

```bash
vivado -mode batch -source syn/vivado/run.tcl -tclargs quick
```

Everything is implemented out of context, so only register-to-register paths
are timed. One line per job is appended to `syn/vivado/results.csv`; the timing
and utilisation reports are in `syn/build/vivado/<job>/`.

## ECP5 (open source)

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
