// top_fpga_ooo.v - Nexys A7 board top for TOMA-RV (Person E)
`timescale 1ns/1ps
// SKELETON (17 Oct task, written 23 Oct 2026). For B's review.
// Ports follow SIGNALS_REFERENCE.md section 2.17; contents follow
// PROJECT_BLUEPRINT.md section 6.16 and decisions D7, D8, D20.
// MMIO rules: docs/mmio_D8_D20.md. Open items: docs/top_fpga_ooo_skeleton.md.
//
// Board / clock / reset (checked against baseline XDC as quoted in blueprint
// section 1.3 and Digilent's Nexys-A7-100T-Master.xdc, 23 Oct):
//   clk   : 100 MHz, pin E3 (CLK100MHZ)
//   reset : active low, pin J15 (= SW[0] on the board; see open item C2)
//   part  : xc7a100tcsg324-1. Physical board still to be seen by E.
//
// What is a placeholder in this skeleton (search "PLACEHOLDER"):
//   * MMCM: core_clk = clk until B's Clocking Wizard instance (D7, 50 MHz)
//     is available. Its module and port names are not in the spec.
//   * LEDs and 7-segment driver: tied off; bit mapping and sw use not
//     specified (open items Q7, Q8).
// Spec-silent MMIO details use E's proposals Q1-Q6 from docs/mmio_D8_D20.md,
// marked "Qn PROPOSAL" below; they change only if A/B decide otherwise.
//
// Submodules are A's pipe_ooo and the baseline instr_mem / data_mem
// (modules/memory.v, never edited), connected by name with the port names of
// SIGNALS_REFERENCE sections 1.2, 1.3, 2.1, and E's perf_counters (2.16).
// Reset: every internal block gets core_reset_n (active low, asserted
// asynchronously, released synchronously to core_clk).
//
// The verilator lint_off/lint_on UNUSEDSIGNAL comments only mark nets that
// the display placeholders do not read yet (and btn); they are comments to
// every other tool and change no logic. Remove them with the placeholders.

module top_fpga_ooo (
    input  wire        clk,      // 100 MHz board clock (E3)
    input  wire        reset,    // active-low reset (J15)
    input  wire [15:0] sw,       // switches
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        btn,      // buttons (optional); width "1+" open (Q9), unused
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [15:0] led,      // status: done flag and low result bits
    output wire [7:0]  seg,      // 7-segment cathodes
    output wire [7:0]  an        // 7-segment anodes
);

    // MMIO addresses (D8, SIGNALS_REFERENCE 2.17)
    localparam [31:0] MMIO_RESULT = 32'h1000_0000;
    localparam [31:0] MMIO_DONE   = 32'h1000_0004;
    localparam [31:0] MMIO_SW     = 32'h1000_0008;
    localparam [3:0]  MMIO_REGION = 4'h1;          // addr[31:28] (D20)

    // ------------------------------------------------------------------
    // Clock. PLACEHOLDER for the MMCM (D7: 50 MHz core clock, owner B).
    // Replace these two assigns with B's Clocking Wizard instance:
    //   clk in -> core_clk (50 MHz), locked -> mmcm_locked.
    // ------------------------------------------------------------------
    wire core_clk;
    wire mmcm_locked;
    assign core_clk    = clk;      // PLACEHOLDER: no MMCM yet
    assign mmcm_locked = 1'b1;     // PLACEHOLDER: no MMCM yet

    // ------------------------------------------------------------------
    // Reset synchronizer (blueprint 6.16). Asynchronous assert when the
    // reset pin is low (or the MMCM is not locked), synchronous release
    // after two core_clk edges.
    // ------------------------------------------------------------------
    wire rst_in_n = reset & mmcm_locked;
    reg  [1:0] rst_sync;
    always @(posedge core_clk or negedge rst_in_n) begin
        if (!rst_in_n) rst_sync <= 2'b00;
        else           rst_sync <= {rst_sync[0], 1'b1};
    end
    wire core_reset_n = rst_sync[1];

    // ------------------------------------------------------------------
    // Core: pipe_ooo (A). Baseline pipe ports (SIGNALS_REFERENCE 1.1),
    // tied exactly as in the baseline testbench/top (2.1), plus the dbg_*
    // outputs of 2.1/2.2 (see open item C1).
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire        exception;
    wire [31:0] pc_out;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] inst_mem_address;
    wire [31:0] inst_mem_read_data;
    wire        dmem_read_ready;
    wire [31:0] dmem_read_address;
    wire [31:0] dmem_read_data_temp;
    wire        dmem_write_ready;
    wire [31:0] dmem_write_address;
    wire [31:0] dmem_write_data;
    wire [3:0]  dmem_write_byte;

    /* verilator lint_off UNUSEDSIGNAL */
    wire        dbg_commit_valid;
    wire [31:0] dbg_commit_pc;
    wire [4:0]  dbg_commit_rd;
    wire        dbg_commit_has_rd;
    wire [31:0] dbg_commit_value;
    wire        dbg_commit_is_store;
    wire        dbg_ooo_event;
    wire        dbg_stall_rob;
    wire        dbg_stall_rs;
    wire        dbg_hold;
    wire [3:0]  dbg_cdb_valid;
    /* verilator lint_on UNUSEDSIGNAL */

    pipe_ooo u_pipe_ooo (
        .clk                 (core_clk),
        .reset               (core_reset_n),
        .stall               (1'b0),
        .inst_mem_is_valid   (1'b1),
        .inst_mem_read_data  (inst_mem_read_data),
        .dmem_read_data_temp (dmem_read_data_temp),
        .dmem_write_valid    (1'b1),
        .dmem_read_valid     (1'b1),
        .exception           (exception),
        .pc_out              (pc_out),
        .inst_mem_address    (inst_mem_address),
        .dmem_read_ready     (dmem_read_ready),
        .dmem_read_address   (dmem_read_address),
        .dmem_write_ready    (dmem_write_ready),
        .dmem_write_address  (dmem_write_address),
        .dmem_write_data     (dmem_write_data),
        .dmem_write_byte     (dmem_write_byte),
        .dbg_commit_valid    (dbg_commit_valid),
        .dbg_commit_pc       (dbg_commit_pc),
        .dbg_commit_rd       (dbg_commit_rd),
        .dbg_commit_has_rd   (dbg_commit_has_rd),
        .dbg_commit_value    (dbg_commit_value),
        .dbg_commit_is_store (dbg_commit_is_store),
        .dbg_ooo_event       (dbg_ooo_event),
        .dbg_stall_rob       (dbg_stall_rob),
        .dbg_stall_rs        (dbg_stall_rs),
        .dbg_hold            (dbg_hold),
        .dbg_cdb_valid       (dbg_cdb_valid)
    );

    // ------------------------------------------------------------------
    // Instruction memory (baseline instr_mem, SIGNALS_REFERENCE 1.2)
    // ------------------------------------------------------------------
    instr_mem u_instr_mem (
        .clk   (core_clk),
        .pc    (inst_mem_address),
        .instr (inst_mem_read_data)
    );

    // ------------------------------------------------------------------
    // MMIO decode (D8, D20)
    // ------------------------------------------------------------------
    wire wr_is_mmio = (dmem_write_address[31:28] == MMIO_REGION);

    // D20: MMIO stores never write data_mem.
    wire        dm_we = dmem_write_ready & ~wr_is_mmio;
    wire [31:0] dm_rdata;

    data_mem u_data_mem (
        .clk   (core_clk),
        .re    (dmem_read_ready),
        .raddr (dmem_read_address),
        .rdata (dm_rdata),
        .we    (dm_we),
        .waddr (dmem_write_address),
        .wdata (dmem_write_data),
        .wstrb (dmem_write_byte)
    );

    // Result and done registers. Written on dmem_write_ready with an exact
    // address match (Q2 PROPOSAL), full data word regardless of
    // dmem_write_byte (Q6 PROPOSAL); done is set by any store to MMIO_DONE
    // and cleared only by reset (Q3, Q4 PROPOSAL).
    /* verilator lint_off UNUSEDSIGNAL */
    reg [31:0] result;
    /* verilator lint_on UNUSEDSIGNAL */
    reg        done;
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            result <= 32'd0;
            done   <= 1'b0;
        end else if (dmem_write_ready) begin
            if (dmem_write_address == MMIO_RESULT) result <= dmem_write_data;
            if (dmem_write_address == MMIO_DONE)   done   <= 1'b1;
        end
    end

    // Switch synchronizer: two flip-flops into core_clk (Q5 PROPOSAL).
    reg [15:0] sw_meta;
    reg [15:0] sw_sync;
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            sw_meta <= 16'd0;
            sw_sync <= 16'd0;
        end else begin
            sw_meta <= sw;
            sw_sync <= sw_meta;
        end
    end

    // D20: the read-data mux selects on the read address registered in the
    // LA cycle (data_mem.rdata returns one cycle later, in LW). The select
    // is updated only when dmem_read_ready = 1, like data_mem.rdata, which
    // holds its value when re = 0.
    //   rd_sel_sw    : last read was MMIO_SW              -> switches
    //   rd_sel_mmio  : last read was another MMIO address -> 0 (Q2 PROPOSAL)
    reg rd_sel_sw;
    reg rd_sel_mmio;
    always @(posedge core_clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            rd_sel_sw   <= 1'b0;
            rd_sel_mmio <= 1'b0;
        end else if (dmem_read_ready) begin
            rd_sel_sw   <= (dmem_read_address == MMIO_SW);
            rd_sel_mmio <= (dmem_read_address[31:28] == MMIO_REGION);
        end
    end

    assign dmem_read_data_temp = rd_sel_sw   ? {16'd0, sw_sync} :  // Q1 PROPOSAL
                                 rd_sel_mmio ? 32'd0 :
                                               dm_rdata;

    // ------------------------------------------------------------------
    // Performance counters (E, SIGNALS_REFERENCE 2.16). run = 0 after done.
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] cycles;
    wire [31:0] retired;
    wire [31:0] ooo_count;
    wire [31:0] rob_stall_cycles;
    wire [31:0] rs_stall_cycles;
    wire [31:0] hold_cycles;
    /* verilator lint_on UNUSEDSIGNAL */

    perf_counters u_perf (
        .clk              (core_clk),
        .reset_n          (core_reset_n),
        .run              (~done),
        .commit_valid     (dbg_commit_valid),
        .ooo_event        (dbg_ooo_event),
        .stall_rob        (dbg_stall_rob),
        .stall_rs         (dbg_stall_rs),
        .hold             (dbg_hold),
        .cycles           (cycles),
        .retired          (retired),
        .ooo_count        (ooo_count),
        .rob_stall_cycles (rob_stall_cycles),
        .rs_stall_cycles  (rs_stall_cycles),
        .hold_cycles      (hold_cycles)
    );

    // ------------------------------------------------------------------
    // Display. PLACEHOLDER: LED bit mapping (Q7) and 7-segment content /
    // switch selection (Q8) are not specified yet. Outputs are tied off;
    // seg/an = all ones = all segments and digits off on the Nexys A7
    // (active-low, Digilent reference manual) [TO VERIFY on the board].
    // ------------------------------------------------------------------
    assign led = 16'd0;
    assign seg = 8'hFF;
    assign an  = 8'hFF;

endmodule
