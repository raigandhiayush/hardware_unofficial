# tomasulo-final — integration notes (27 Oct 2026)

Merged from `NewDay/hardware_unofficial` (latest tests, tools, evidence) and
`tomasulo-new/tomasulo` (the team's latest Vivado project). Both source folders were left untouched.

## Where each file came from

| Content | Source | Why |
|---|---|---|
| Everything (RTL, tests, programs, tools, scripts, evidence, `.git`) | `NewDay/hardware_unofficial` | Complete tree; its `ooo_rtl/` is byte-identical to the `NewDay/tomasulo` Vivado project that routed on 25 Oct (WNS +1.624 ns, WHS +0.030 ns at 50 MHz, bitstream written) |
| `ooo_rtl/imem.hex` | `tomasulo-new/tomasulo/tomasulo.srcs/sources_1/new/imem.hex` | Addition program that writes its result (0x66) and `done` over MMIO; the previous image never set `done` |

Not copied: `simulation/build/*` and `tools/__pycache__/` (regenerated), the Vivado project/run folders.

## What was compared (tomasulo-new vs hardware_unofficial, `ooo_rtl/`)

- Identical: `alu_fu.v`, `instr_queue.v`, `mul_unit.v`, `ooo_decode.v`, `ooo_frontend.v`, `rs_array.v`, `dmem.hex`; also `tb_ooo_core.v`.
- Comments only: `ooo_core.v`, `ooo_dispatch.v`, `pipe_ooo.v`, `ooo_defs.vh`, `rat.v`, `regfile_2r1w.v`, `rob.v`, `div_unit.v`, `lsu.v`, `perf_counters.v`, and the `.xdc` (same pins).
- `memory.v`: tomasulo-new's copy equals `modules/memory.v` (path `../mem_generator/imem_dmem/imem.hex`); `ooo_rtl/memory.v` loads `imem.hex` (for a Vivado project with `imem.hex` added as a source). Logic identical.
- **`top_fpga_ooo.v`: tomasulo-new's copy is broken and was NOT used.** Its MMCM block is commented out, so `core_clk` and `locked` have no driver. Its 26 Oct 19:26 run logs `Synth 8-3848 Net core_clk ... does not have driver` and the placed design has **0 LUTs and 0 registers** (the CPU was optimised away; that bitstream does nothing). The version here keeps the MMCM and the `` `ifdef TOMA_SIM `` simulation clock.

## Checks run on this folder (27 Oct 2026, Icarus 12.0)

- `bash simulation/run_unit_tests.sh a`: all 26 tests PASS, vector counts equal to the 26 Oct run; logs `evidence/20261027_*`.
- The Vivado GUI file set below (`ooo_rtl/*.v`, `-DTOMA_SIM`) with the new `imem.hex`: result `0x00000066`, done 1, exception 0, 27 cycles, 19 retired (= reference model), ooo_count 2. Scratch testbench, not saved as evidence.
- Not run: Vivado synthesis/implementation of this folder.

## Vivado GUI project (top_fpga_ooo)

- Design sources: all 17 `ooo_rtl/*.v`, `ooo_rtl/ooo_defs.vh`, `ooo_rtl/imem.hex`. Do not also add `modules/memory.v` (duplicate `instr_mem`/`data_mem`).
- Constraints: `ooo_fpga/top_fpga_ooo.xdc`.
- Simulation source: `ooo_tests/tb_ooo_core.v` (or another `ooo_tests/tb_*.v`); add `TOMA_SIM` to the simulation defines when simulating `top_fpga_ooo`.
- Top: `top_fpga_ooo`. Part: `xc7a100tcsg324-1`.
- After synthesis, check the log for `imem.hex is read successfully` and the utilization for non-zero LUTs.

Scripted alternative (other programs, or `pipe_m` / `pipe`):
`vivado -mode batch -source ooo_fpga/synth_vivado.tcl -tclargs bit <program.hex> [ooo|pipe_m|pipe]`.
