//////////////// Including Stages ////////////////////////////
`timescale 1ns/1ps
// pipe_m - the baseline 3-stage pipe (modules/pipeline.v, untouched) plus
// in-order RV32M: same ports, same behaviour on RV32I code (no freeze ever
// happens there). A MUL/DIV in EX freezes the pipeline (md_freeze, from
// execute_m) until its result is back (blueprint 4.3 edit point 3):
//   - stall_all = stall_read | md_freeze holds fetch_pc, ID/EX, EX/WB and the
//     WB-stage registers, and blocks the register-file write;
//   - instr_mem is not frozen, so the instruction that sat in ID when the
//     freeze began is saved (id_inst_sv) and replayed until ID moves again;
//   - the store in WB is held for the whole freeze but written only once,
//     in the cycle the freeze ends (like its register write).
// Also fixed (timing unchanged, see execute_m): wrong-path register writes are
// dropped in EX, so the register file and forwarding no longer check wb_stall.
// Also fixed (timing unchanged): sub-word loads pick their byte/halfword with
// the load's own registered offset (wb_read_address); the baseline passes
// dmem_read_address[1:0], the address of the instruction now in EX.
// Also fixed (timing unchanged): the ID-stage pc is id_pc, which follows
// fetch_pc like instr_mem does. The baseline's inst_fetch_pc (wb.v) is held
// during wb_stall, so the first two instructions at a taken-branch target got
// a stale pc (wrong branch target / link value).
 module pipe_m
#(
	parameter [31:0]         	RESET = 32'h0000_0000
)
(
	input               	clk,
	input               	reset,
	input               	stall,
	output          	exception,  
	output [31:0] pc_out,

	// interface of instruction Memory
	input               	inst_mem_is_valid,
	input       	[31: 0] inst_mem_read_data,
	input       	[31: 0] dmem_read_data_temp,
	input               	dmem_write_valid,
	input               	dmem_read_valid,
	output      [31: 0] inst_mem_address,
	output              dmem_read_ready,
	output      [31: 0] dmem_read_address,
	output              dmem_write_ready,
	output      [31: 0] dmem_write_address,
	output      [31: 0] dmem_write_data,
	output      [3: 0] dmem_write_byte
);
    
	//Declaring Wires and Registers

	//Data Memory Wires
    
	wire      	[31: 0] dmem_read_data;
	// wire              	dmem_write_ready;
	// wire              	dmem_read_ready;
	// wire      	[31: 0] dmem_write_address;
	// wire      	[31: 0] dmem_read_address;
	wire        	[1:0]  dmem_read_offset;
	// wire      	[31: 0] dmem_write_data;
	// wire      	[ 3: 0] dmem_write_byte;
	wire              	inst_mem_is_ready;
	wire              	dmem_read_valid_checker;
    
	//Instruction Fetch/Decode Stage
    
	reg       	[31: 0] immediate;
	wire               	immediate_sel;
	wire       	[ 4: 0] src1_select;
	wire       	[ 4: 0] src2_select;
	wire       	[ 4: 0] dest_reg_sel;
	wire       	[ 2: 0] alu_operation;
	wire               	arithsubtype;
	wire               	mem_write;
	wire               	mem_to_reg;
	wire               	illegal_inst;
	wire       	[31: 0] execute_immediate;
	wire               	muldiv;
	wire               	alu;
	wire               	lui;
	wire               	jal;
	wire               	jalr;
	wire               	branch;
	reg               	stall_read;
	wire      	[31: 0] instruction;
	wire      	[31: 0] reg_rdata2 ;
	wire      	[31: 0] reg_rdata1;
	reg       	[31: 0] regs [31: 1];

	// PC

	wire        	[31: 0] pc;
	wire        	[31: 0] inst_fetch_pc;
	reg        	[31: 0] fetch_pc ;  

	//Stalls
    
	wire 	wb_stall_first;
	wire 	wb_stall_second;
	wire	wb_stall;   	 
        	 
       	 
	//Execute Stage

    
	wire         	[31: 0] next_pc;
	wire        	[31: 0] write_address;
	wire                 	branch_taken;
	wire                	branch_stall;
	wire                	md_freeze;
	wire                	stall_all = stall_read | md_freeze;
	reg                 	md_freeze_d;
	reg         	[31:0] id_inst_sv;
	reg         	[31:0] id_pc;
	wire        	[31:0] alu_operand1;
	wire        	[31:0] alu_operand2;

	// Write Back
    
	wire                	wb_alu_to_reg;
	wire        	[31: 0] wb_result;
	wire        	[ 2: 0] wb_alu_operation;
	wire                	wb_mem_write;
	wire                	wb_mem_to_reg;
	wire        	[ 4: 0] wb_dest_reg_sel;
	wire                	wb_branch;
	wire                	wb_branch_nxt;
	wire        	[31: 0] wb_write_address;
	wire        	[ 1: 0] wb_read_address;
	wire        	[ 3: 0] wb_write_byte;
	wire        	[31: 0] wb_write_data;
	wire        	[31: 0] wb_read_data;
	// wire       	[31: 0] inst_mem_address;

//------------------------------------------------------//
assign dmem_write_address       	= wb_write_address; 	// assigning where to write
assign dmem_read_address        	= alu_operand1 + execute_immediate;  // Assigning address to read from the data memory
assign dmem_read_offset = dmem_read_address[1:0];
assign dmem_read_ready          	= mem_to_reg;   // load instruction flag to read from memory
assign dmem_write_ready         	= wb_mem_write && !md_freeze; 	// flag to write into the memory, once per store
assign dmem_write_data          	= wb_write_data;	// assigning data to write
assign dmem_write_byte          	= wb_write_byte;	// flag for writing the data bytes
assign dmem_read_data           	= dmem_read_data_temp;  	// data read from the memory
assign dmem_read_valid_checker  	= 1'b1;
// -----------------------------------------------------//

// instantiating Instruction fetch module -----------------------
IF_ID_m IF_ID_stage (
	.clk            	(clk),
	.reset          	(reset),
	.stall          	(stall),
	.exception      	(exception),

	// Instruction memory interface
	.inst_mem_is_valid  (inst_mem_is_valid),
	.inst_mem_read_data (md_freeze_d ? id_inst_sv : inst_mem_read_data),

	// Previously pipe.* signals (now explicit ports)
	.stall_read_i   	(stall_all),
	.inst_fetch_pc  	(id_pc),
	.instruction_i  	(instruction),

	// WB-stage signals
	.wb_stall       	(wb_stall),
	.wb_alu_to_reg  	(wb_alu_to_reg),
	.wb_mem_to_reg  	(wb_mem_to_reg),
	.wb_dest_reg_sel	(wb_dest_reg_sel),
	.wb_result      	(wb_result),
	.wb_read_data   	(wb_read_data),

	// Instruction memory address offset
	.inst_mem_offset	(inst_mem_address[1:0]),

	// Output wires (write-only)
	.execute_immediate_w (execute_immediate),
	.immediate_sel_w	(immediate_sel),
	.alu_w          	(alu),
	.lui_w          	(lui),
	.jal_w          	(jal),
	.jalr_w         	(jalr),
	.branch_w       	(branch),
	.mem_write_w    	(mem_write),
	.mem_to_reg_w   	(mem_to_reg),
	.arithsubtype_w 	(arithsubtype),
	.pc_w           	(pc),
	.src1_select_w  	(src1_select),
	.src2_select_w  	(src2_select),
	.dest_reg_sel_w 	(dest_reg_sel),
	.alu_operation_w	(alu_operation),
	.illegal_inst_w 	(illegal_inst),
	.muldiv_w       	(muldiv),
	.instruction_o  	(instruction)
);


////////////////////////////////////////////////////////////
// TODO: Register File Forwarding
//
// - If src register is x0 (5'd0) → return 0
// - If WB stage writes same register (and not stalled) → forward:
//    	wb_read_data (for LOAD)
//    	wb_result	(for ALU)
// - Else → read from register array (regs)
////////////////////////////////////////////////////////////

assign reg_rdata1 =
	(src1_select == 5'd0) ? 32'd0:
	(wb_alu_to_reg &&
 	(wb_dest_reg_sel == src1_select))
    	? (wb_mem_to_reg ? wb_read_data : wb_result)
    	: regs [src1_select];

assign reg_rdata2 = 
    (src2_select == 5'd0) ? 32'd0:
	(wb_alu_to_reg &&
 	(wb_dest_reg_sel == src2_select))
    	? (wb_mem_to_reg ? wb_read_data : wb_result)
    	: regs [src2_select];

////////////////////////////////////////////////////////////
// TODO: Register File Writeback
//
// On reset:
//   - Clear registers x1-x31
//
// On valid WB cycle:
//   - If wb_alu_to_reg asserted
//   - AND no stall
//   - Write either:
//    	wb_read_data (LOAD)
//    	wb_result	(ALU result)
////////////////////////////////////////////////////////////

integer i;
always @(posedge clk or negedge reset) begin
	if (!reset) begin
    	for (i = 1; i < 32; i = i + 1)
        	regs[i] <= 32'd0;
	end
	else if (wb_alu_to_reg && !stall_all && 
	wb_dest_reg_sel != 5'd0) begin
    	regs[wb_dest_reg_sel] <=
        	wb_mem_to_reg ? wb_read_data : wb_result;
	end
end


////////////////////////////////////////////////////////////
// Stall register
////////////////////////////////////////////////////////////

always @(posedge clk or negedge reset) begin
	if (!reset)
    	stall_read <= 1'b1;
	else
    	stall_read <= stall;
end

////////////////////////////////////////////////////////////
// MUL/DIV freeze: keep the instruction that was in ID
////////////////////////////////////////////////////////////

always @(posedge clk or negedge reset) begin
	if (!reset) begin
    	md_freeze_d <= 1'b0;
    	id_inst_sv  <= 32'h0;
	end
	else begin
    	md_freeze_d <= md_freeze;
    	if (md_freeze && !md_freeze_d)
        	id_inst_sv <= inst_mem_read_data;
	end
end

// pc of the instruction in ID: instr_mem returns the word at last cycle's fetch_pc
always @(posedge clk or negedge reset) begin
	if (!reset)
    	id_pc <= RESET;
	else if (!stall_all)
    	id_pc <= fetch_pc;
end


// instantiating execute module -----------------------------------
execute_m execute (
	// -----------------
	// Clock / Reset
	// -----------------
	.clk          	(clk),
	.reset        	(reset),

	// -----------------
	// FROM ID/EX
	// -----------------
	// ---- TODO: Connect ID/EX signals ----
	// .reg_rdata1   ( ... ),
	// Add remaining ID/EX connections here
	.reg_rdata1     (reg_rdata1),
    .reg_rdata2     (reg_rdata2),
    .execute_imm      (execute_immediate), 
    .pc(pc),
    .fetch_pc(fetch_pc),
    .immediate_sel(immediate_sel),
    .mem_write(mem_write),
    .jal(jal),
    .jalr(jalr),
    .lui(lui),
    .alu(alu),
    .branch         (branch),
    .muldiv         (muldiv),
    .arithsubtype   (arithsubtype),
    .mem_to_reg     (mem_to_reg),
    .stall_read     (stall_read),
    .dest_reg_sel   (dest_reg_sel),
    .alu_op         (alu_operation),
    .dmem_raddr     (dmem_read_offset),

	// -----------------
	// FROM WB
	// -----------------
	.wb_branch_i  	(wb_branch),
	.wb_branch_nxt_i  (wb_branch_nxt),

	// -----------------
	// EX → PIPE
	// -----------------
	.alu_operand1 	(alu_operand1),
	.alu_operand2 	(alu_operand2),
	.write_address	(write_address),
	.branch_stall 	(branch_stall),
	.md_freeze    	(md_freeze),
	.next_pc      	(next_pc),
	.branch_taken 	(branch_taken),

	// -----------------
	// EX → WB
	// -----------------
	// ---- TODO: Connect EX → WB signals ----
	.wb_result        (wb_result),
	.wb_mem_write     (wb_mem_write),
	.wb_alu_to_reg    (wb_alu_to_reg),
	.wb_dest_reg_sel  (wb_dest_reg_sel),
	.wb_branch        (wb_branch),
	.wb_branch_nxt    (wb_branch_nxt),
	.wb_mem_to_reg    (wb_mem_to_reg),
	.wb_read_address  (wb_read_address),
	.mem_alu_operation(wb_alu_operation)
);



////////////////////////////////////////////////////////////
// PC Update Logic
//
// On reset:
// - Set PC = RESET
//
// On each clock (if not stalled):
// - If branch_stall = 1 → hold branch redirect and
// move sequentially (PC = PC + 4).
// - Else → update PC with next_pc
// (this could be normal next or a jump/branch address).
//
// stall_read prevents any PC update.
////////////////////////////////////////////////////////////

always @(posedge clk or negedge reset) begin
	if (!reset)
    	fetch_pc <= RESET;
	else if (!stall_all)
    	fetch_pc <= branch_stall
                     	? fetch_pc + 4
                     	: next_pc;
end


// instantiating Writeback module ----------------------------------
wb wb_stage (
   .clk(clk),
   .reset(reset),
   // TODO: Connect WB inputs
   .stall_read_i        (stall_all),
   .fetch_pc_i          (fetch_pc),
   .wb_branch_i         (branch_taken),
   .wb_mem_to_reg_i     (mem_to_reg),
   .mem_write_i         (mem_write),
   .write_address_i     (write_address),
   .alu_operand2_i      (alu_operand2),
   .alu_operation_i     (alu_operation),
   .wb_alu_operation_i  (wb_alu_operation),
   .wb_read_address_i   (wb_read_address),
   .dmem_read_data_i    (dmem_read_data),
   .dmem_write_valid_i  (dmem_write_valid),
   // TODO: Connect WB outputs
    .inst_mem_address_o  (inst_mem_address),
   .inst_mem_is_ready_o (inst_mem_is_ready),
   .wb_stall_o          (wb_stall),
   .wb_write_address_o  (wb_write_address),
   .wb_write_data_o     (wb_write_data),
   .wb_write_byte_o     (wb_write_byte),
   .wb_read_data_o      (wb_read_data),
   .inst_fetch_pc_o     (inst_fetch_pc),
   .wb_stall_first_o    (wb_stall_first),
   .wb_stall_second_o   (wb_stall_second)
);

assign pc_out = fetch_pc;

endmodule