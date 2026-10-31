# TOMA-RV: Branch Speculation and Slow Data Memory

**Folder:** `tomasulo-rv-spec/`, a copy of `tomasulo-rv-cache/` (which was not modified). `report.md` is still the cache report; this one covers the additions.
**Date:** 30 Oct 2026. **Simulator:** Icarus Verilog 12.0. **Status:** verified in simulation only. **Not synthesized, not run on the board.** Nothing committed; this folder has no `.git`.

## 1. Result

Default build: 2-bit + BTB speculation, 2-way write-back L1, data memory with 10 wait cycles. Regression 37/37 PASS (`bash simulation/run_unit_tests.sh a`).

Total cycles, 13 programs (the C workloads and hand-written tests):

| Memory wait | Spec off, no cache | Spec off, write-back | Spec on, no cache | **Spec on, write-through** | **Spec on, write-back** |
|---|---|---|---|---|---|
| 0 | 2,736 | 2,863 | 2,620 | 2,677 | 2,742 |
| 2 | 3,148 | 2,908 | 3,010 | 2,726 | 2,787 |
| 5 | 3,786 | 2,974 | 3,650 | 2,868 | 2,853 |
| **10 (default)** | 4,906 | 3,084 | 4,833 | 3,116 | **2,963** |
| 20 | 7,193 | 3,304 | 7,185 | 3,696 | 3,183 |

- At wait 10, the default build takes **40 % fewer cycles** than no cache and no speculation (4,906 → 2,963).
- Almost all of that is the cache: 4,833 → 2,963 with speculation on. Speculation alone gives about 1.5–4 % on these programs.
- The cache wins from wait 2 upward. At wait 0 it still loses, as `report.md` found.
- **The wait is a model, chosen by hand, and it decides the size of this gain.** That is the point of the change, but report it as "on a simulated memory with N wait cycles", not as a property of the board.

Requested workloads at wait 10:

| Program | Retired | Spec off, no cache | Default build | Write-back hit rate |
|---|---|---|---|---|
| `base_rv32i` | 310 | 888 (CPI 2.865) | **448 (CPI 1.445)** | 97 % |
| `sort_d8` | 127 | 605 (CPI 4.764) | **219 (CPI 1.724)** | 95 % |
| `addition_d8` | 18 | 84 | **54** | 71 % |
| `top_mmio` | 92 | 258 (CPI 2.804) | 262 (CPI 2.848), **no gain** | 77 % |

Hit rates include wrong-path loads. Baseline `pipe` / `pipe_m` have no wait support, so they cannot be compared on slow memory; at wait 0 they are still faster on `base_rv32i` (408 vs 437 with speculation and write-through) and `sort_d8` (147 vs 195).

## 2. Speculation

Fetch predicts with `ooo_rtl/bpred.v`: 16-entry tagged BTB and 64 2-bit counters. Dispatch checks each prediction against the decoded instruction. Conditional branches then dispatch past themselves, with up to 3 unresolved (one per ALU reservation station). JAL is learned at dispatch. **JALR is not predicted:** dispatch still holds until it resolves, and none of the workloads dispatch one.

**Recovery is at branch resolve**, one cycle later from registers (`flush_*` in `ooo_core`):
- The ROB computes a `squash` mask of everything younger and rewinds its tail. RS and LSQ drop those entries.
- The RAT restores a checkpoint taken at the branch. Each checkpoint also watches commits, so it is still right when restored.
- MUL, DIV and the in-flight load are killed. Tags are ROB entry numbers and get reused straight away, so a survivor would falsely complete a new instruction. The divider aborts rather than running on.
- A wrong-path refill is allowed to finish; its data is valid, only the response is ignored.

**Other changes speculation forces:**
- `exception` is now set at commit, because wrong-path fetches reach illegal words.
- MMIO loads wait until they are the oldest instruction.
- The predictor trains on committed branches only.
- `ooo_count` now counts committed instructions that finished while an older one waited, because wrong-path completions must not count. **It is not comparable with the old per-cycle number.**

### Measured gain, no cache, wait 0

| Program | Spec off | Spec on | Estimate I gave earlier |
|---|---|---|---|
| `base_rv32i` | 517 | **431** | 426 |
| `mul_d8` | 140 | **119** | 99 |
| `div_d8` | 552 | **536** | 388 |
| `rv32m_d8` | 277 | **276** | 127 |
| `sort_d8` | 187 | **186** | 186 |
| `top_mmio` | 173 | **182 (slower)** | 176 |

**My earlier "about 16 %" estimate was too high.** I warned it was optimistic, but it was well off on the DIV-heavy programs: measured total is **4.2 %** on the 13 programs (2,736 → 2,620). Later instructions still wait on the single divider, as flagged at the time.

- **Accuracy:** 63 % on the 13 programs (111 branches, too few to warm up), 83 % on the stress programs (2,480 branches).
- **It can hurt:** `top_mmio` above, and `sort_d8` with no cache at wait 10 (605 → 630), because a wrong-path load holds the memory until it finishes.
- **Stress programs** gain more (33,703 → 27,567, 18 %), but they are constructed loop-heavy tests. **Do not quote them as typical workloads** (D17).

## 3. Slow data memory

`ooo_rtl/mem_wait.v` sits between the core and `data_mem` in the board top. `MEM_WAIT=0` is a straight wire.

- The first access costs `MEM_WAIT` extra cycles (default 10). The next sequential word costs none, like a DRAM burst, so a line fill pays once.
- One access at a time, with a 4-entry write buffer that drains before reads, so reads see all earlier stores.
- Handshake uses the baseline `pipe`'s previously unused `dmem_read_valid` and `dmem_write_valid` inputs. MMIO bypasses it. **Instruction memory is unchanged.**

The default of 10 is an assumption about off-chip latency, not a measurement. A store's commit still cannot wait, so the LSU only starts a store when the write buffer has room.

**Default policy is now write-back.** I chose write-through before, when writes were free. On slow memory write-back wins from wait 5 up (at wait 10: 2,963 vs 3,116), so that reasoning no longer applies.

## 4. Verification (`evidence/20261030_*`)

| Check | Result |
|---|---|
| Older test suite, `SPEC_EN=0 MEM_WAIT=0 DC_WB=0` | All PASS. Cycle-identical to `tomasulo-rv-cache` on all 12 finishing programs it shares |
| `tb_commit_trace`, 22 programs vs reference model (13,065 commits) | PASS: default, write-through, no cache, wait 0 |
| Same, predictor randomly corrupted while running ("chaos") | PASS: write-back and write-through |
| All 30 sweep configurations | PASS, identical results everywhere (`20261030_a_spec_mem_sweep.log`) |
| `tb_ooo_core` random RV32IM vs ISA model, speculation on | PASS, forward branches only |
| `tb_l1_dcache` (now 5 configs, 2 on slow memory) | PASS 635,099 |
| New: `tb_bpred`, `tb_mem_wait` | PASS 1,300 / 9,031 |
| Board self-test `tb_top_fpga_ooo` on the default build | PASS, reads memory through the cache |

**Stress programs** (`tools/gen_spec_programs.py`, 8 programs): nested loops, data-dependent branches, branches waiting on MUL, DIV or a load with work behind them, JAL, JALR, MMIO, wrong-path illegal words, and a checksum of registers and memory at the end.

**Injected bugs:** 18 of 18 caught, with the predictor corruption on. They covered killing MUL (both stages) and DIV and the load, RAT restore and checkpoint upkeep, ROB, RS and LSQ squash, flush ordering, dispatch during flush, the recovery address, exception timing, read ordering and the refill handshake. The first version of the stress generator missed both MUL cases, so I added late-resolving branches to it. A simulation monitor also flags any broadcast to an unallocated ROB entry.

## 5. Open items

1. **No synthesis, timing or board run.** The core gained a predictor, checkpoints (372 flip-flops of RAT copies), a fan-out-heavy squash mask and a fetch-stage BTB lookup, and the 25 Oct pre-cache build had only +1.624 ns of slack. Timing closure at 50 MHz is the main risk.
2. **Interface changes for the decision log:** D9 (no speculation) is reversed. New ports on `lsu`, `rob`, `rat`, `rs_array`, `mul_unit`, `div_unit`, `instr_queue`, `ooo_frontend`, `ooo_dispatch`, `ooo_core`, `pipe_ooo`, `perf_counters`, `l1_dcache`. `rs_al_op[6]` now carries the prediction (D16 had it 0). Display gains `sw[12]` (branches / mispredicts).
3. **Test scope:** `tb_ooo_event_trace`, `tb_ooo_dispatch`, `tb_ooo_frontend` and other older tests run with speculation off, because they assert the old hold or cycle-exact timing. `tb_baseline_counters` and `tb_ooo_core` run write-through at wait 0, because they check stores on the memory port and the baselines have no wait support.
4. **The BTB and JALR:** no return predictor, and no workload exercises a hot JALR.

## 6. Run it

```
bash simulation/run_unit_tests.sh a                  # full regression, logs in evidence/
python3 -I tools/gen_spec_programs.py 8              # regenerate the stress programs
iverilog ... -DSPEC_EN=0 -DMEM_WAIT=5 -DDC_WB=0 ...  # any configuration (see ooo_defs.vh)
vivado -mode batch -source ooo_fpga/synth_vivado.tcl -tclargs bit ooo_tests/programs/sort_d8.hex ooo
```

Vivado GUI: add `bpred.v`, `mem_wait.v` and `l1_dcache.v` to the sources. Board display: `sw[15:13]` as before (with `sw[13]=1` the cache page); `sw[12]=1` shows branches, or mispredicts with `sw[14]=1`.
