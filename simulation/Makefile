# --- Variables ---
INC_DIR  = ../ooo_rtl
BFLAGS   = -i $(INC_DIR) -f filelist.txt
TOP_MOD  = top_fpga_ooo
SNAPSHOT = riscv_sim
MEM_GEN  = ../mem_generator

# Vivado Tools
XVLOG = xvlog
XELAB = xelab
XSIM  = xsim

.PHONY: help clean sort addition negative

help:
	@echo "Usage: make <program_name> (e.g. make addition)"

# Generic Rule for all programs
xor sort addition negative div:
	# 1. Generate Hex Files
	$(MAKE) clean -C $(MEM_GEN)
	$(MAKE) $@ -C $(MEM_GEN)
	
	# 2. Vivado Simulation Flow
	$(XVLOG) $(BFLAGS)
	$(XELAB) -top $(TOP_MOD) -snapshot $(SNAPSHOT) -debug typical
	
	# 3. Run Simulation (log to stdout to see display)
	$(XSIM) $(SNAPSHOT) -runall -log stdout

clean:
	@rm -rf xsim.dir/ .Xil/
	@rm -f xvlog.log xvlog.pb xelab.log xelab.pb xsim.log xsim.jou xsim.pb
	@rm -f pipeline.vcd
