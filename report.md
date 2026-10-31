# TOMA-RV — L1 Data Cache Integration Report

**Folder:** `tomasulo-rv-cache/`, a copy of `tomasulo-final/` with the cache added. `tomasulo-final/` was not modified.
**Date:** 27 Oct 2026. **Simulator:** Icarus Verilog 12.0. **Status:** verified in simulation; **not synthesized** (no Vivado on the machine that did this work). Nothing has been committed.

---

## 1. Summary

| Item | Result |
|---|---|
| `ooo_rtl/l1_dcache.v` | New. 2-way set-associative (direct-mapped by parameter), 4- or 8-word lines, LRU bit per set, write-through/no-write-allocate (**default**) or write-back/write-allocate with a dirty bit per line (`DC_WB=1`), 1-cycle hit, MMIO bypass |
| Integration | Between the LSU and the core's memory port inside `ooo_core`. The `pipe_ooo` memory ports and the board top's memory and MMIO logic are unchanged |
| Store safety | Stores reach the cache only in their ROB commit cycle |
| Counters | `dcache_access_count`, `dcache_hit_count`, `dcache_miss_count`, `dcache_stall_cycles` in `perf_counters`; also shown on the 7-segment display with `sw[13]=1` |
| Unit test | `tb_l1_dcache`: **PASS 354,695 checks**; all 5 injected RTL bugs are caught |
| Regression | **27 / 27 PASS** (`bash simulation/run_unit_tests.sh a`) |
| Whole programs | 968 commits on 13 programs match the reference model in **6 cache configurations** and with the cache off |
| Cache off (`DC_EN=0`) | **Cycle-identical** to the pre-cache core on all 12 programs |
| Performance | **No CPI improvement, and none is possible on this memory system.** `data_mem` already answers in 1 cycle, so a hit only ties it and a miss costs more. Default configuration: **+2.8 % total cycles** (2,219 → 2,282). Hit rates 36–90 % on the requested workloads. See §6 |
| I-cache | Not implemented (optional). See §8 |

---

## 2. Memory interface before the cache

These are the files the brief asked me to inspect, and what they do now.

- **`lsu.v`:** in-order LSQ (4 entries); only the head entry acts.
  - **Load:** in cycle LA it drives `dmem_re` with base + imm and leaves the queue. In LA+1 (LW) the word from `data_mem` is formatted (LB/LH/LBU/LHU) and broadcast on `cdb_lsu`.
  - **Store:** in cycle SR it broadcasts a dummy on `cdb_lsu` (so the ROB marks it ready). Then it waits; in the cycle the ROB commits it (`cm_valid & cm_is_store & cm_tag`) it drives `dmem_we` and leaves the queue.
  - **Byte lanes:** SB/SH replicate the data and set `wstrb`.
  - **D13 rule:** a store's SR may not fall on a load's LW cycle.
- **`memory.v` (`data_mem`):** synchronous read with data in the next cycle; the output holds when `re=0`. Write happens in the same cycle with byte strobes. Same-cycle read and write to one word forward the new bytes. It is 4 KB and decodes `addr[11:2]`, so higher addresses alias.
- **`rob.v` / `ooo_core.v`:** one in-order commit per cycle. The ROB **cannot be back-pressured**: a store commits whether or not memory is "ready", which is why the commit-cycle store write is a hard constraint.
- **`ooo_frontend.v`:** instruction fetch from `instr_mem` (BRAM, 1 cycle) into a 4-entry queue. It has no memory stall input.
- **`ooo_defs.vh`:** MMIO is `addr[31:28] == 4'h1` (`0x1000_0000` result, `0x1000_0004` done, `0x1000_0008` switches). The decode lives in `top_fpga_ooo.v` (D8, D20). `docs/mmio_D8_D20.md`, named in the brief, is not in this repo. There is no UART; the MMIO range above is the whole region.
- **No speculation (blueprint invariant):** dispatch stops after a branch or JALR until it resolves, so no wrong-path load or store ever exists. Loads start only after all older stores have committed (rule 11).

---

## 3. Cache design (`ooo_rtl/l1_dcache.v`)

### 3.1 Parameters (`ooo_defs.vh`, each overridable with `-D`)

| Define | Default | Meaning |
|---|---|---|
| `DC_EN` | 1 | 0 = no cache; the LSU talks to `data_mem` directly (bit-for-bit the old behaviour) |
| `DC_WAYS` | 2 | 1 (direct-mapped) or 2 (one LRU bit per set) |
| `DC_SETS` | 8 | sets per way (power of 2, ≥ 2) |
| `DC_WORDS` | 4 | words per line: 4 (16 B) or 8 (32 B) |
| `DC_WB` | 0 | 0 = write-through / no-write-allocate, 1 = write-back / write-allocate |
| `DC_MEM_AW` | 12 | address bits `data_mem` decodes |

The default is 2 × 8 × 16 B = **256 B**. The address split is `[1:0]` byte, `[3:2]` word, `[6:4]` set, `[11:7]` tag (5 bits).

Storage is 2,048 data bits, 80 tag bits, 16 valid bits, 16 dirty bits and 8 LRU bits.

**Tags cover only `addr[11:0]`.** That way addresses which alias in `data_mem` (for example the stack at `0xFFFF_Fxxx` and `0x0000_0xxx`) also share one cache line, and the cached system sees exactly the memory the uncached one does. With full 32-bit tags, two aliases would be cached as two different lines and could go stale.

### 3.2 Ports

- **LSU side:** `req_valid, req_we, req_addr, req_wdata, req_byte_en` in; `stall, resp_ready, resp_data` out.
  - `resp_ready` means "the load's word is on `resp_data` this cycle".
- **Memory side:** the `data_mem` protocol (`mem_re/raddr/rdata`, `mem_we/waddr/wdata/wstrb`).
- **Events:** `ev_access, ev_hit, ev_miss, ev_stall`.

### 3.3 FSM

```
                 accept (req_valid & ~stall), tag compare in the same cycle
   +------------------------------------------------------------------------+
   |  S_IDLE (COMPARE_TAG)                                                   |
   |   load hit  -> word registered, resp_ready next cycle, stay IDLE        |
   |   store hit -> merge bytes into the line (WB: dirty; WT: also to memory)|
   |   WT store miss -> write memory only (no allocate), stay IDLE           |
   |   MMIO store -> pass to the memory port this cycle, stay IDLE           |
   |   MMIO load  -> pass mem_re this cycle --------------------> S_MMIO      |
   |   load miss / WB store miss: victim = invalid way, else LRU             |
   |        victim dirty (WB only) ------------------------> S_WRITEBACK      |
   |        otherwise ---------------------------------------> S_REFILL      |
   +------------------------------------------------------------------------+
   S_WRITEBACK: one victim word per cycle to memory (WORDS cycles) -> S_REFILL
   S_REFILL (ALLOCATE / MEM_READ): one read per cycle, each word written as it
        arrives a cycle later; a write-allocated store is merged into its word;
        after the last word: tag, valid, dirty (= store), LRU, and for a load
        resp_ready = 1 in the next cycle -> S_IDLE
   S_MMIO (MMIO_PASS): resp_ready = 1, resp_data = mem_rdata -> S_IDLE
```

**`stall = (state != S_IDLE)` is a register output**, so it is constant for the whole cycle and adds no combinational path back into the LSU. The cache never reads and writes memory in the same cycle. The testbench checks that.

### 3.4 Timing (default 4-word lines)

| Access | LSU-visible latency | Cache busy (stall) |
|---|---|---|
| Load hit | 1 cycle (same as `data_mem`) | 0 |
| Load miss, clean victim | WORDS + 2 = **6** | 5 |
| Load miss, dirty victim (WB) | 2·WORDS + 2 = **10** | 9 |
| MMIO load | 1 | 1 |
| Store hit, WT store miss, MMIO store | no response | 0 |
| WB store miss (allocate) | no response | 5 (9 if the victim is dirty) |

### 3.5 Store safety and the commit-cycle problem

- Stores enter the cache **only** in their ROB commit cycle (the LSU's `st_commit`), so the cache never holds data from an uncommitted instruction.
- Loads probe the cache as soon as they reach the LSQ head, which is safe because this core never executes wrong-path instructions.
- The problem: a store's commit write **cannot wait**, because the ROB has no back-pressure, yet the cache can be busy servicing a miss. The LSU solves this without touching the ROB:
  - A store may start SR only while `stall=0`.
  - Between its SR and its commit the store is the LSQ head, so no other access can start.
  - So the cache is guaranteed idle when the store commits.
- A simulation-only check in `l1_dcache.v` prints `TEST_FAIL` if a request ever arrives while `stall=1`. It never fired in any run.

### 3.6 Why write-through is the default

Both policies are implemented and verified. Write-through is the default for three reasons:

1. **Speed.** On this system it is faster in every program (§6). Writes to `data_mem` are free (it has its own write port and finishes in one cycle), so write-back saves nothing, while write-allocate adds 5–9 busy cycles to each store miss.
2. **Commit-cycle store contract.** Every committed store still appears on the core's memory port in its commit cycle. Existing checks of that contract (`tb_commit_trace`, `tb_ooo_core`, `tb_baseline_counters`) stay valid unchanged.
3. **Coherence.** `data_mem` is always up to date, for debugging and for anything that reads it directly.

The "write buffer" the brief mentions for write-through is not needed: memory accepts one write per cycle, and the cache makes at most one request per cycle.

---

## 4. Integration changes

None of these changes alter the `pipe_ooo` memory ports or the board top's memory and MMIO wiring. The first four rows are **interface changes against `iface-v1`, to log in A's decision log.**

| File | Change |
|---|---|
| `ooo_rtl/lsu.v` | **Interface:** new inputs `dmem_stall` and `dmem_rvalid`. LA and SR start only while `dmem_stall=0`. A load stays in flight until `dmem_rvalid`, and the `cdb_lsu` broadcast uses that cycle. With `stall=0, rvalid=1` it reduces exactly to the old logic. |
| `ooo_rtl/ooo_core.v` | **Interface:** new outputs `dbg_dc_access/hit/miss/stall`. Instantiates `l1_dcache` between the LSU and `dmem_*` (`generate` on `DC_EN`; `DC_EN=0` wires the LSU straight through). The LSU's separate read and write ports merge into one request (they are never active together). |
| `ooo_rtl/pipe_ooo.v` | **Interface:** passes the 4 `dbg_dc_*` outputs through. The baseline `pipe` port list is unchanged; these sit with the existing `dbg_*` outputs. |
| `ooo_rtl/perf_counters.v` | **Interface:** 4 new inputs and 4 new 32-bit counters, with the same rules as the others (count while `run`, asynchronous reset, wrap). |
| `ooo_rtl/top_fpga_ooo.v` | Connects the counters. Display: `sw[13]=1` shows a cache page (`sw[15:14]`: 00 accesses, 01 hits, 10 misses, 11 stall cycles); `sw[13]=0` is unchanged. |
| `ooo_rtl/ooo_defs.vh` | `DC_*` defines (§3.1). |
| `baseline_fpga/top_fpga_base.v` | Ties the new counter inputs to 0 (the baselines have no cache). |
| `simulation/run_unit_tests.sh`, `measure_cycles.sh`, `filelist.txt`, `ooo_fpga/synth_vivado.tcl` | `l1_dcache.v` added to every source list. New test `tb_l1_dcache`. `tb_ooo_event_trace` now built with `-DDC_EN=0` (§5.3). |
| `simulation/Makefile` | New target `make dcache_test` (xvlog / xelab / xsim). |

**Vivado GUI project:** add `ooo_rtl/l1_dcache.v` to the design sources, which makes 18 `.v` files in `ooo_rtl/` plus `ooo_defs.vh` and `imem.hex`.

### Testbench changes

| Testbench | Change |
|---|---|
| `tb_lsu` | Ties `dmem_stall=0, dmem_rvalid=1`. The original LSU tests run unchanged against the original timing. |
| `tb_perf_counters` | Random stimulus on the 4 new inputs in every cycle, a reference model for each new counter, and preload/wrap coverage. 1,123,336 checks. |
| `tb_top_fpga_ooo` | Display check extended to the `sw[13]` page. Its `sw` values exercise both pages. |
| `tb_commit_trace` | Prints the cache statistics per program. With `DC_WB=1` the commit-cycle store check reads the LSU→cache request port, because a write-back cache keeps stores out of memory. Otherwise it is unchanged. |
| `tb_baseline_counters` | Prints a `DCACHE` line per program and checks hits + misses = accesses. |

---

## 5. Verification

### 5.1 `tb_l1_dcache` (new): PASS 354,695 checks

Three configurations run side by side. Each has the **real `data_mem`** and an MMIO device model built like `top_fpga_ooo` (registered read source, MMIO stores never reach `data_mem`):

| Harness | Configuration | Ops (MMIO) | Hits | Misses | Dirty write-backs | Checks |
|---|---|---|---|---|---|---|
| H0 | 2-way, 8 sets, 4 words, write-back | 6,060 (388) | 1,429 | 4,243 | 1,286 | 105,438 |
| H1 | 2-way, 8 sets, 4 words, write-through | 6,060 (364) | 1,434 | 4,262 | — | 85,654 |
| H2 | direct-mapped, 4 sets, 8 words, write-back | 6,060 (400) | 744 | 4,916 | 1,399 | 163,600 |

**What it checks.** The driver behaves like the LSU. Every access is compared against two independent models.

- **Golden memory:**
  - every load value, including `data_mem` aliasing and MMIO device values;
  - at the end, memory seen through the cache (dirty lines over `data_mem`) equals the golden memory on **all 1,024 words**;
  - for write-through, `data_mem` alone must equal it.
- **Cache-state model** (tags, valid, dirty, LRU kept in the testbench), for every access:
  - hit or miss;
  - whether a write-back happens;
  - the **exact load latency** (1 / WORDS+2 / 2·WORDS+2);
  - the number of memory reads and writes.
- **Protocol:** one response per load and none per store, `stall=0` never leaves a response pending, no memory read and write in the same cycle, and the event outputs.

**Cases covered, as the brief listed them:**

| Brief's case | Covered by |
|---|---|
| Read hit / write hit | 0x104 after 0x100; store 0x108 |
| Read miss, clean replacement | three lines in the 0x200 set, clean victim |
| Read miss, dirty write-back | store 0x300, two more lines, reload 0x300 returns the stored value |
| Byte / halfword (SB / SH) | SB lanes 0 and 1, SH upper and lower half, then word reads |
| MMIO pass-through | MMIO loads; MMIO store and read-back of a device register; MMIO stores leave the aliased `data_mem` words unchanged |
| Back-to-back RAW | load issued the cycle after a store hit; 16 back-to-back loads |
| Also | store miss (allocate or not); aliasing above 4 KB |
| Random | 6,000 operations per harness over a 1 KB region (conflicts in every set), aliases and MMIO |

**LB/LH/LBU/LHU sign and zero extension** happens in the LSU, after the cache. It is covered at core level, with the cache on:
- `tb_ooo_core` runs directed LB/LBU/LH/LHU/LW loads plus random loads of every width against its ISA model (15,161 commits, 0 failures).
- `tb_baseline_counters` runs `base_rv32i.s` (which uses `lbu`, `sh` and `sb`) to the correct result, with the right retired count and the right address, lanes and strobes for every store.

**Mutation check.** Each of these bugs, injected into a scratch copy of `l1_dcache.v`, makes the test fail with thousands of mismatches:
- write-back skipped: 9,255 failures
- LRU inverted: 2,480
- MMIO cached: 3,783
- no merge of a write-allocated store: 6,463
- write-through not writing memory: 4,031

The testbench also found a real RTL bug during development. In the direct-mapped build the victim select was an `always @*` block reducing to a constant. Such a block never runs in simulation, so the victim stayed X. It is now a continuous `assign`.

### 5.2 Full regression: 27 / 27 PASS (`evidence/20261027_*`)

Compared with the pre-cache run of the same suite (`tomasulo-final`, 27 Oct), every count is the same except these:

| Test | Before → after | Why |
|---|---|---|
| `tb_l1_dcache` | new: 354,695 | — |
| `tb_perf_counters` | 674,060 → 1,123,336 | 4 new counters checked |
| `tb_ooo_core` | 113,080 → 113,496 | Same 15,161 commits, 0 failures. Longer load latency means more per-cycle checks. **1,549 cycles with ≥ 2 buses active** with the cache on. |
| `tb_ooo_system` | 130 → 129 | Fixed 600-cycle window; the slower cached core completes 129 stores instead of 130, all matching the baseline |

### 5.3 Whole programs in every configuration (`evidence/20261027_a_dcache_sweep.log`)

`tb_commit_trace` (968 commits on 13 programs against `tools/ref_model.py`, results via MMIO) passes in all 6 configurations: no cache, the default, write-back, direct-mapped, 8-word lines and 16 sets. `tb_baseline_counters` passes with and without the cache.

**With `DC_EN=0` the cycle count equals the pre-cache core exactly on all 12 programs.**

`tb_ooo_event_trace` replays a hand-built program (`ooo_trace.s`) whose timing was designed so that the first load's result meets another bus in the same cycle. With the cache, that load is a cold miss and broadcasts in cycle 17 instead of 12, so the coincidence disappears (0 two-bus cycles instead of 1). All 14 commits are still correct. The test now runs with `-DDC_EN=0`, the timing it was built for. Multi-bus behaviour of the **cached** core is covered by `tb_ooo_core` (1,549 two-or-more-bus cycles).

---

## 6. Performance

All numbers are cycles in simulation, from `run` to `done` inclusive (D21). CPI = cycles / retired instructions. "No cache" is the same RTL with `DC_EN=0`, identical to the pre-cache core.

### 6.1 Requested workloads

| Program | Retired | pipe (baseline) | pipe_m | OoO, no cache | OoO + L1 (default) | Δ | Hit rate (hits / accesses) |
|---|---|---|---|---|---|---|---|
| `base_rv32i` | 310 | 408 (CPI 1.316) | 408 (1.316) | 517 (1.668) | **527 (1.700)** | +1.9 % | 90.3 % (93 / 103) |
| `sort_d8` | 127 | 147 (1.157) | 147 (1.157) | 187 (1.472) | **196 (1.543)** | +4.8 % | 83.6 % (46 / 55) |
| `addition_d8` | 18 | 22 (1.222) | 22 (1.222) | 25 (1.389) | **30 (1.667)** | +20 % | 42.9 % (3 / 7) |
| `top_mmio` | 92 | N/A (uses RV32M) | 147 (1.598) | 173 (1.880) | **188 (2.043)** | +8.7 % | 36.4 % (8 / 22) |

### 6.2 All programs, all configurations (cycles)

| Program | No cache | **WT 2-way 8×4 (default)** | WB 2-way 8×4 | WT direct 8×4 | WT 2-way 4×8 | WT 2-way 16×4 |
|---|---|---|---|---|---|---|
| top_mmio | 173 | 188 | 206 | 188 | 196 | 188 |
| ooo_trace | 52 | 52 | 52 | 52 | 52 | 52 |
| rv32m_edge | 526 | 526 | 539 | 526 | 526 | 526 |
| mul_d8 | 140 | 145 | 147 | 145 | 149 | 145 |
| div_d8 | 552 | 562 | 564 | 562 | 570 | 562 |
| rv32m_d8 | 277 | 286 | 291 | 286 | 294 | 286 |
| addition_d8 | 25 | 30 | 34 | 30 | 34 | 30 |
| sort_d8 | 187 | 196 | 200 | 196 | 204 | 196 |
| negative_d8 | 25 | 30 | 34 | 30 | 34 | 30 |
| xor_d8 | 25 | 30 | 34 | 30 | 34 | 30 |
| mul_stream | 59 | 59 | 59 | 59 | 59 | 59 |
| muldiv_stream | 178 | 178 | 178 | 178 | 178 | 178 |
| **Total** | **2,219** | **2,282 (+2.8 %)** | 2,338 (+5.4 %) | 2,282 | 2,330 (+5.0 %) | 2,282 |

Write-back has the **higher hit rate**, for example sort_d8 94.5 % vs 83.6 % and top_mmio 77.3 % vs 36.4 %. Its stores allocate lines that later loads hit. It is still **slower**, because each allocation costs 5–9 stall cycles while a write-through store miss costs none. `mul_stream` and `muldiv_stream` make no memory accesses.

### 6.3 Reading these numbers honestly

- **The brief asked for "CPI and hit-rate improvements over the baseline". There is no CPI improvement, and there cannot be one on this memory system.** `data_mem` is on-chip memory with a 1-cycle read, exactly the latency of a cache hit. A hit therefore ties the old timing and every miss adds 5–9 cycles. The cost is largest on short programs, which are mostly cold misses (addition_d8: 4 of its 7 accesses miss).
- A cache pays off when the backing memory is slower than the cache, for example the Nexys A7's DDR2 or a multi-cycle memory. This design is built for that case: the LSU now tolerates any load latency, and only `l1_dcache`'s memory side would need a ready/valid handshake added.
- Against the in-order baselines, the OoO core was already slower on these RV32I programs before the cache (e.g. sort 187 vs 147). The cache does not change that comparison's direction. Per D17, speed-ups are only claimed where measured. The L1 adds none.

---

## 7. How to reproduce

From `tomasulo-rv-cache/`:

```
bash simulation/run_unit_tests.sh a                    # full regression, logs in evidence/
bash simulation/run_unit_tests.sh a tb_l1_dcache       # cache unit test only
iverilog -g2012 -I ooo_rtl -o simulation/build/tb_l1_dcache \
    modules/memory.v ooo_rtl/l1_dcache.v ooo_tests/tb_l1_dcache.v && (cd simulation && vvp -n build/tb_l1_dcache)
bash simulation/measure_cycles.sh ooo_tests/programs/sort_d8.hex   # PERF + DCACHE lines
cd simulation && make dcache_test                      # same unit test under Vivado xsim
```

To run another cache configuration, add defines to the compile command, e.g. `-DDC_WB=1`, `-DDC_WAYS=1`, `-DDC_WORDS=8 -DDC_SETS=4`, or `-DDC_EN=0`.

---

## 8. Not done, open items, risks

1. **No synthesis, timing or FPGA run.** Vivado is not installed here. Unknowns:
   - **Utilization.** The data array is written from two places (hit store, refill), so Vivado may build it from about 2 K flip-flops plus muxes rather than LUT-RAM.
   - **Timing at 50 MHz.** The new combinational path in the request cycle is LSU address adder → set index → tag compare (2 ways) → data mux → register. The team's 25 Oct routed build of the pre-cache core had WNS +1.624 ns, which leaves little margin.

   Run `ooo_fpga/synth_vivado.tcl` and check WNS and utilization before using this build on the board.
2. **I-cache not implemented** (the brief marks it optional). `instr_mem` is a 1-cycle BRAM, so an I-cache could only add misses. `ooo_frontend.v` also has no fetch-stall input, so adding one would be a new frontend interface change. I'd rather not do that 9 days before the final report.
3. **Interface changes** (§4) need A's sign-off and a decision-log entry: the `lsu` ports, the `dbg_dc_*` outputs, the `perf_counters` ports, the `sw[13]` display page and the `ooo_defs.vh` defines.
4. `tb_ooo_event_trace` runs without the cache (§5.3).
5. **Git:** `tomasulo-rv-cache/.git` is a copy of `tomasulo-final/.git`, which was re-initialised on 27 Oct, between 19:06 and 19:31, outside this work. It has a GitHub remote, all files staged and **no commits**, so the test logs record `Commit: none`. No git command that writes was run.

---

## 9. Files

**New**
- `ooo_rtl/l1_dcache.v` (276 lines)
- `ooo_tests/tb_l1_dcache.v` (398 lines)
- `evidence/20261027_a_dcache_sweep.log`
- `evidence/20261027_*` (regression logs)
- `report.md`

**Modified**
- RTL: `ooo_rtl/{lsu.v, ooo_core.v, pipe_ooo.v, perf_counters.v, top_fpga_ooo.v, ooo_defs.vh}`, `baseline_fpga/top_fpga_base.v`
- Testbenches: `ooo_tests/{tb_lsu.v, tb_perf_counters.v, tb_top_fpga_ooo.v, tb_commit_trace.v}`, `simulation/tb_baseline_counters.v`
- Build: `simulation/{run_unit_tests.sh, measure_cycles.sh, filelist.txt, Makefile}`, `ooo_fpga/synth_vivado.tcl`
- `evidence/INDEX.md` (two rows)

`modules/` (the reference baseline) is untouched.
