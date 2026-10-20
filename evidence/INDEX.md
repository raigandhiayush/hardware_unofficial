# Evidence index — TOMA-RV

One line per saved log. Regenerate the unit-test rows with
`bash simulation/run_unit_tests.sh <your-letter>` (from `tomasulo-rv/`).
Every log carries date, tool version, exact command, commit, exit status, simulated cycles and PASS/FAIL.
No synthesis, timing or FPGA evidence exists yet (no Vivado run).

Baseline notes (imported 20 Oct from `RISCV_Three_Stage.zip`, byte-identical, `modules/` untouched):
- Only the xor program's `imem.hex` is present; no RISC-V compiler on the importing machine, so addition/sort/negative were not rebuilt.
- `modules/tb_pipeline.v` differs from the version the blueprint audited (143 vs 129 lines): it stops at PC 0x44 (xor-specific) and prints a computed time, not `$time`. Use `simulation/tb_baseline_probe.v` for cycle evidence.
- After reset the baseline executes its first instruction twice (`addi sp,sp,-32` lands in `sp` at two consecutive cycles), so its stack sits 0x20 below the architectural value of F8 (stores at `0xFFFFFFDC`.. instead of `0xFFFFFFFC`..). `tb_ooo_system` therefore compares store data, byte lanes and address pattern with one constant address offset.
- The baseline `exception` output pulses once per loop pass: the squashed fetch after `ret` reads 0x00000000 and IF_ID flags it illegal without checking the squash (F10). Our core must raise `exception` only for a dispatched illegal instruction (D12).

| Date | Test | Module (owner) | Spec | Result | Log |
|---|---|---|---|---|---|
| 2026-10-20 | tb_alu_fu | alu_fu (C) | blueprint 6.9 | PASS 2067 | `20261020_c_alu_fu_tb_alu_fu.log` |
| 2026-10-20 | tb_rs_array | rs_array (C) | blueprint 6.8 | PASS 63 | `20261020_c_rs_array_tb_rs_array.log` |
| 2026-10-20 | tb_alu_path | rs_array + alu_fu (C) | rules 4, 5 | PASS 25 | `20261020_c_alu_path_tb_alu_path.log` |
| 2026-10-20 | tb_ooo_frontend | ooo_frontend + instr_queue (C, D) | blueprint 6.4, rule 12 | PASS 20579 | `20261020_c_ooo_frontend_tb_ooo_frontend.log` |
| 2026-10-20 | tb_regfile_2r1w | regfile_2r1w (E) | blueprint 6.5 | PASS 46399 | `20261020_e_regfile_2r1w_tb_regfile_2r1w.log` |
| 2026-10-20 | tb_div_unit | div_unit (E) | blueprint 6.11, rule 6 (latency 33) | PASS 24146 | `20261020_e_div_unit_tb_div_unit.log` |
| 2026-10-20 | tb_instr_queue | instr_queue (D) | blueprint 6.3 | PASS 10040 | `20261020_d_instr_queue_tb_instr_queue.log` |
| 2026-10-20 | tb_instr_queue (DEPTH=8) | instr_queue (D), count-width fix | blueprint 6.3 | PASS 10056 (old 3-bit-count version: 45218 failures) | `20261020_d_instr_queue_d8_tb_instr_queue_d8.log` |
| 2026-10-20 | tb_mul_unit | mul_unit (D) | blueprint 6.10, rule 6 (t+2) | PASS 100420 | `20261020_d_mul_unit_tb_mul_unit.log` |
| 2026-10-20 | tb_ooo_decode | ooo_decode (D) | blueprint 6.2 (44 instr + illegal, 200k random words vs MATCH/MASK) | PASS 500183 | `20261020_d_ooo_decode_tb_ooo_decode.log` |
| 2026-10-20 | tb_rob | rob (B) | blueprint 6.7, rules 2, 8 | PASS 20059 | `20261020_b_rob_tb_rob.log` |
| 2026-10-20 | tb_lsu | lsu (B) | blueprint 6.12, rules 7, 11, D10, D13 | PASS 46413 | `20261020_b_lsu_tb_lsu.log` |
| 2026-10-20 | tb_lsu (+define REAL_DMEM) | lsu (B) with the real baseline `data_mem` | blueprint 6.12 "uses the real data_mem", 19 Oct latency check | PASS 46413 | `20261020_b_lsu_realmem_tb_lsu_realmem.log` |
| 2026-10-20 | tb_baseline_probe | baseline `pipe` (untouched), xor program | blueprint 1.3, TASKS 14 Oct baseline log | PASS 50 stores; loop 20 cycles / 18 instr (CPI 1.11) | `20261020_b_baseline_probe_tb_baseline_probe.log` |
| 2026-10-20 | tb_rat | rat (A) | blueprint 6.6, rule 10 | PASS 5144 | `20261020_a_rat_tb_rat.log` |
| 2026-10-20 | tb_ooo_dispatch | ooo_dispatch (A) + ooo_decode | blueprint 6.13, rule 3, D11–D16 (every operand source, each bus, two buses in one cycle, each class, each stall, sticky exception) | PASS 52 | `20261020_a_ooo_dispatch_tb_ooo_dispatch.log` |
| 2026-10-20 | tb_ooo_core | pipe_ooo / ooo_core (A), all modules | blueprint 6.14, §3.6: directed program + 60 random 300-instruction RV32IM programs, every commit and store vs an ISA model in the testbench, final register file | PASS 113080 (15161 commits; out-of-order completion and multi-bus cycles observed) | `20261020_a_ooo_core_tb_ooo_core.log` |
| 2026-10-20 | tb_ooo_system | pipe_ooo vs baseline `pipe` on `imem.hex` (xor) | blueprint 6.14 | PASS 130 stores identical (address offset 0x20, see baseline notes); no `exception` | `20261020_a_ooo_system_tb_ooo_system.log` |
| 2026-09-28 | team xsim run of `tb_pipeline` (xor) | baseline `pipe` | reference output, xsim v2025.2 | stores 0, 0, 10, 3, 9 (Icarus run of the same tb reproduces it exactly) | `20260928_team_baseline_xor_xsim_stdout.log` |

Superseded (no date/tool/command header, or run against an older `ooo_defs.vh`; kept for history): `tb_alu_fu.log`, `tb_alu_path.log`, `tb_ooo_frontend.log`, `tb_rs_array.log`, `tb_rat.log`.

Every module in `ooo_rtl/` has a passing testbench, and the integrated core passes `tb_ooo_core` and `tb_ooo_system`. C's earlier wiring fragment `ooo_core_personC.v` was merged into `ooo_core.v` and removed.
