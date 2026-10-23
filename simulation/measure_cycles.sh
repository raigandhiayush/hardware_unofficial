#!/usr/bin/env bash
# measure_cycles.sh - D21 cycle counts of one program on pipe (baseline), pipe_m
# (baseline + in-order MUL/DIV) and pipe_ooo, with tb_baseline_counters.
# Usage, from anywhere:
#     bash simulation/measure_cycles.sh [prog.hex] [sw-hex]
# Default prog.hex = mem_generator/imem_dmem/imem.hex (what `make <prog>_d8` writes).
# The expected trace comes from tools/ref_model.py; the program must end with the
# done store (D8). Prints the PERF lines and the speed-ups; exit status non-zero
# unless TEST_PASS.
set -eu
cd "$(dirname "$0")/.."                      # tomasulo-rv/
HEX="$(realpath "${1:-mem_generator/imem_dmem/imem.hex}")"
SW="${2:-0}"
mkdir -p simulation/build
TRACE="$PWD/simulation/build/measure.trace"
python3 -I tools/ref_model.py "$HEX" --sw "0x$SW" -o "$TRACE"

CORE="ooo_rtl/pipe_ooo.v ooo_rtl/ooo_core.v ooo_rtl/ooo_frontend.v ooo_rtl/instr_queue.v ooo_rtl/ooo_decode.v ooo_rtl/ooo_dispatch.v ooo_rtl/rat.v ooo_rtl/regfile_2r1w.v ooo_rtl/rob.v ooo_rtl/rs_array.v ooo_rtl/alu_fu.v ooo_rtl/mul_unit.v ooo_rtl/div_unit.v ooo_rtl/lsu.v"
iverilog -g2012 -DTOMA_SIM -I ooo_rtl -I modules -o simulation/build/tb_baseline_counters \
  ooo_rtl/top_fpga_ooo.v ooo_rtl/perf_counters.v $CORE modules/memory.v \
  modules/pipeline.v modules/IF_ID.v modules/execute.v modules/wb.v \
  baseline_m/pipeline_m.v baseline_m/IF_ID_m.v baseline_m/execute_m.v \
  simulation/tb_baseline_counters.v
out="$(cd simulation && vvp -n build/tb_baseline_counters +hex="$HEX" +trace="$TRACE" +sw="$SW")"
echo "$out" | grep -E '^(PERF|BASELINE_BUG|TEST_)'
echo "$out" | awk '/^PERF/ && /cycles=/ { split($3, c, "="); split($7, n, "="); cyc[c[2]] = n[2] }
  END {
    if (cyc["pipe_ooo"] == "") exit
    if (cyc["pipe"]   != "") printf "speed-up pipe   / pipe_ooo = %.3f\n", cyc["pipe"]   / cyc["pipe_ooo"]
    if (cyc["pipe_m"] != "") printf "speed-up pipe_m / pipe_ooo = %.3f\n", cyc["pipe_m"] / cyc["pipe_ooo"]
  }'
echo "$out" | grep -q '^TEST_PASS'
