#!/usr/bin/env bash
# build_test_programs.sh - assemble ooo_tests/programs/*.s with tools/rvasm.py and
# write the reference-model commit traces used by tb_commit_trace / tb_top_fpga_ooo.
# Usage (from anywhere): bash tools/build_test_programs.sh
set -eu
cd "$(dirname "$0")/.."                      # tomasulo-rv/
P=ooo_tests/programs
for s in "$P"/*.s; do
  python3 -I tools/rvasm.py "$s" -o "${s%.s}.hex"
done
# expected traces: <program> <sw value> <max commits>
python3 -I tools/ref_model.py "$P/top_mmio.hex"   --sw 0xA5A5 -o "$P/top_mmio.trace"
python3 -I tools/ref_model.py "$P/ooo_trace.hex"  -o "$P/ooo_trace.trace"
python3 -I tools/ref_model.py "$P/rv32m_edge.hex" -o "$P/rv32m_edge.trace"
python3 -I tools/ref_model.py mem_generator/imem_dmem/imem.hex --max 200 -o "$P/xor_baseline.trace"
