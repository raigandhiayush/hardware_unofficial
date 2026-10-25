#//////////////////////////////////////////////////////
#/////////////////INCLUDING CROSS-COMPILER/////////////

CC      = riscv-none-elf-gcc
AR      = riscv-none-elf-ar
OBJDUMP = riscv-none-elf-objdump
OBJCOPY = riscv-none-elf-objcopy
READELF = riscv-none-elf-readelf


#///// flags for RV32i architecture///////////////////
CFLAGS  = -march=rv32i -mabi=ilp32


#////Source for c code file ///////////////////////////
SRC_ADDITION     = code_addition_d8.c
SRC_SORT     = code_sort_d8.c
SRC_NEGATIVE = code_negative_d8.c
SRC_XOR = code_xor_d8.c
SRC_DIV = code_div_d8.c
SRC_MUL = code_mul_d8.c

TARGET   = code.elf

.PHONY: all clean

#/// generating .text file of code cross-compiled from highlevel-c code to risc-v code
# ////////////// Copying and converting the text file into binary files
#/////// Python script to convert the binary files into the required hex files

#//////////////////////////////////////////////////////
#///// D8 workloads (PROJECT_BLUEPRINT.md 6.17; owner D, reviewer E)
#///// make <prog>_d8     : -march=rv32i  (baseline and OoO, comparison D17)
#///// make <prog>_d8_im  : -march=rv32im (OoO only; RV32M workloads)
#///// -mno-relax lets the assembler resolve local branches, so the object
#///// has no relocations; tools/check_elf.py rejects the build otherwise (F3).
#///// Only .text goes into imem (the core starts at pc 0 = main).
D8_CFLAGS = -mabi=ilp32 -mno-relax -O0
CHECK_ELF = python ../tools/check_elf.py

define D8_BUILD
	$(CC) -c $(1) -o $(TARGET) -march=$(2) $(D8_CFLAGS)
	$(CHECK_ELF) $(TARGET)
	$(OBJCOPY) -O binary -j .text $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py
endef

%_d8_im: code_%_d8.c
	$(call D8_BUILD,$<,rv32im)

%_d8: code_%_d8.c
	$(call D8_BUILD,$<,rv32i)

# /////clean function
clean:
	$(RM) $(TARGET) ./imem_dmem/imem.bin ./imem_dmem/imem.hex ./imem_dmem/dmem.bin ./imem_dmem/dmem.hex ./imem_dmem/code.dis
