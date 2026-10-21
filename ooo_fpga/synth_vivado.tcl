# synth_vivado.tcl - non-project Vivado build of top_fpga_ooo (owner: B)
# PROJECT_BLUEPRINT.md 6.16, D7. Run from tomasulo-rv/ooo_fpga/ so that instr_mem's
# $readmemh("../mem_generator/imem_dmem/imem.hex") finds the workload image:
#   cd ooo_fpga && vivado -mode batch -source synth_vivado.tcl -tclargs synth   (synthesis only)
#   cd ooo_fpga && vivado -mode batch -source synth_vivado.tcl -tclargs impl    (+ place/route)
#   cd ooo_fpga && vivado -mode batch -source synth_vivado.tcl                  (+ bitstream)
# Reports go to ooo_fpga/build/; copy the .rpt files into evidence/ with the
# Vivado version and commit hash (DoD).
set part  xc7a100tcsg324-1
set stage [expr {[llength $argv] > 0 ? [lindex $argv 0] : "bit"}]
set out   ./build
file mkdir $out

set rtl {
	../ooo_rtl/top_fpga_ooo.v ../ooo_rtl/perf_counters.v ../ooo_rtl/pipe_ooo.v
	../ooo_rtl/ooo_core.v ../ooo_rtl/ooo_frontend.v ../ooo_rtl/instr_queue.v
	../ooo_rtl/ooo_decode.v ../ooo_rtl/ooo_dispatch.v ../ooo_rtl/rat.v
	../ooo_rtl/regfile_2r1w.v ../ooo_rtl/rob.v ../ooo_rtl/rs_array.v
	../ooo_rtl/alu_fu.v ../ooo_rtl/mul_unit.v ../ooo_rtl/div_unit.v ../ooo_rtl/lsu.v
	../modules/memory.v
}
read_verilog $rtl
read_xdc top_fpga_ooo.xdc

synth_design -top top_fpga_ooo -part $part -include_dirs ../ooo_rtl
write_checkpoint -force $out/post_synth.dcp
report_utilization    -file $out/post_synth_utilization.rpt
report_timing_summary -file $out/post_synth_timing.rpt
if {$stage eq "synth"} { exit }

opt_design
place_design
route_design
write_checkpoint -force $out/post_route.dcp
report_utilization    -file $out/post_route_utilization.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_drc            -file $out/post_route_drc.rpt
if {$stage eq "impl"} { exit }

write_bitstream -force $out/top_fpga_ooo.bit
