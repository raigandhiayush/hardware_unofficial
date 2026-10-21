# synth_vivado.tcl - non-project Vivado build of top_fpga_ooo (owner: B)
# PROJECT_BLUEPRINT.md 6.16, D7. Can be run from any directory:
#   vivado -mode batch -source ooo_fpga/synth_vivado.tcl -tclargs synth [prog.hex]  (synthesis only)
#   vivado -mode batch -source ooo_fpga/synth_vivado.tcl -tclargs impl  [prog.hex]  (+ place/route)
#   vivado -mode batch -source ooo_fpga/synth_vivado.tcl -tclargs bit   [prog.hex]  (+ bitstream)
# prog.hex (1024 lines, one 32-bit word each) is the program in instr_mem; it defaults
# to ooo_tests/programs/top_mmio.hex (the program tb_top_fpga_ooo runs). Expected on
# the board after CPU_RESET: led[15] (done) on, display = 00000003 with sw[15:14]=00,
# cycles 000000AD (173) with 01, retired 0000005C (92) with 10.
#
# instr_mem (modules/memory.v, never edited) loads "../mem_generator/imem_dmem/imem.hex"
# relative to Vivado's working directory. The script copies prog.hex to
# build/mem_generator/imem_dmem/imem.hex and runs Vivado in build/run, so the baseline
# mem_generator/imem_dmem/imem.hex (used by the baseline and tb_ooo_system) is untouched.
#
# The build stops with an error if the hex file cannot be read, if a latch is
# inferred, or if routed setup/hold slack is negative (no bitstream is written then).
# Reports go to ooo_fpga/build/; copy the .rpt files into evidence/ with the
# Vivado version and commit hash (DoD).
set here  [file dirname [file normalize [info script]]]
set repo  [file dirname $here]
set part  xc7a100tcsg324-1
set stage [expr {[llength $argv] > 0 ? [lindex $argv 0] : "bit"}]
set hex   [file normalize [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$repo/ooo_tests/programs/top_mmio.hex"}]]
set out   $here/build

if {[lsearch -exact {synth impl bit} $stage] < 0} {
	error "stage must be synth, impl or bit (got '$stage')"
}

# ---- program image ----------------------------------------------------------
if {![file readable $hex]} { error "program image not readable: $hex" }
set fh    [open $hex r]
set words {}
foreach line [split [read $fh] "\n"] {
	regsub {//.*$} $line {} line                    ;# $readmemh comments
	set line [string trim $line]
	if {$line eq ""} continue
	if {![regexp {^[0-9A-Fa-f]{8}$} $line]} { close $fh; error "$hex: bad word '$line'" }
	lappend words $line
}
close $fh
if {[llength $words] < 1 || [llength $words] > 1024} {
	error "$hex has [llength $words] words; instr_mem holds 1024"
}
file mkdir $out/mem_generator/imem_dmem $out/run
file copy -force $hex $out/mem_generator/imem_dmem/imem.hex
cd $out/run
puts "instr_mem image: $hex ([llength $words] words)"

# missing $readmem file or an inferred latch is fatal
set_msg_config -id {Synth 8-4445} -new_severity ERROR
set_msg_config -id {Synth 8-327}  -new_severity ERROR

# ---- synthesis --------------------------------------------------------------
set rtl {
	ooo_rtl/top_fpga_ooo.v ooo_rtl/perf_counters.v ooo_rtl/pipe_ooo.v
	ooo_rtl/ooo_core.v ooo_rtl/ooo_frontend.v ooo_rtl/instr_queue.v
	ooo_rtl/ooo_decode.v ooo_rtl/ooo_dispatch.v ooo_rtl/rat.v
	ooo_rtl/regfile_2r1w.v ooo_rtl/rob.v ooo_rtl/rs_array.v
	ooo_rtl/alu_fu.v ooo_rtl/mul_unit.v ooo_rtl/div_unit.v ooo_rtl/lsu.v
	modules/memory.v
}
foreach f $rtl { read_verilog $repo/$f }
read_xdc $here/top_fpga_ooo.xdc

synth_design -top top_fpga_ooo -part $part -include_dirs $repo/ooo_rtl
write_checkpoint -force $out/post_synth.dcp
report_utilization    -file $out/post_synth_utilization.rpt
report_timing_summary -file $out/post_synth_timing.rpt
if {$stage eq "synth"} { exit }

# ---- implementation ---------------------------------------------------------
opt_design
place_design
route_design
write_checkpoint -force $out/post_route.dcp
report_utilization    -file $out/post_route_utilization.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_drc            -file $out/post_route_drc.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "routed WNS = $wns ns, WHS = $whs ns"
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
	error "timing not met (WNS '$wns', WHS '$whs'); see $out/post_route_timing.rpt"
}
if {$stage eq "impl"} { exit }

write_bitstream -force $out/top_fpga_ooo.bit
