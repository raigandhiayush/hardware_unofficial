# program_board.tcl - load ooo_fpga/build/top_fpga_ooo.bit into the Nexys A7 over USB-JTAG
# (volatile: lost at power-off). Run after synth_vivado.tcl, board plugged in and on:
#   vivado -mode batch -source ooo_fpga/program_board.tcl
set bit [file dirname [file normalize [info script]]]/build/top_fpga_ooo.bit
if {![file readable $bit]} { error "no bitstream at $bit; run synth_vivado.tcl first" }

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} { error "no xc7a100t on the JTAG chain" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "programmed $dev with $bit; press CPU_RESET to restart the program"
close_hw_manager
