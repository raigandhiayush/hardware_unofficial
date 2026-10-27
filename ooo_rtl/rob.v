`timescale 1ns/1ps
// rob.v - reorder buffer and commit for TOMA-RV (Person B)
// Spec: PROJECT_BLUEPRINT v0.3 sec. 6.7, rules 2/8/9 of sec. 3.6, D11, D12,
// D15, D18; ports: SIGNALS_REFERENCE v0.3 sec. 2.8.
//
// Contract:
//   * Allocate: rob_al_valid writes the tail entry and rob_al_tag names it.
//     Full is judged on the count at the START of the cycle (rule 2), so an
//     allocate while rob_full is ignored even if the head commits this cycle.
//     rob_al_pre = 1 (CLS_PRE / CLS_NOP) makes the entry ready at once with
//     rob_al_value; otherwise it waits for a bus (D11, D12).
//   * Complete: four write ports, one per CDB. Every bus write is handled the
//     same way (D15: JALR's link value arrives on cdb_alu like any result).
//   * Commit: cm_valid = head valid & ready. ready is a register written at
//     the end of the broadcast cycle W, so commit is never earlier than W+1
//     (rule 8). The head is freed at the clock edge.
//   * Read ports are combinational from the state at the start of the cycle;
//     a value broadcast this cycle is the dispatch bypass's job (rule 3).
//   * ooo_event (D18): some active bus carries a tag other than the head
//     while the head is valid and not ready.
//   * reset_n: active low, asynchronous; clears every entry and pointer.

`include "ooo_defs.vh"

module rob #(
    parameter ROB_N = `ROB_N,
    parameter ROB_W = `ROB_W
) (
    input  wire                     clk,
    input  wire                     reset_n,
    // allocate (dispatch)
    input  wire                     rob_al_valid,
    input  wire [`KIND_W-1:0]       rob_al_kind,
    input  wire                     rob_al_has_rd,
    input  wire [`REG_W-1:0]        rob_al_rd,
    input  wire [`XLEN-1:0]         rob_al_pc,
    input  wire                     rob_al_pre,
    input  wire [`XLEN-1:0]         rob_al_value,
    output wire [ROB_W-1:0]         rob_al_tag,
    output wire                     rob_full,
    output wire                     rob_empty,
    output wire [ROB_W:0]           rob_count,
    // operand read ports (dispatch)
    input  wire [ROB_W-1:0]         rob_rd_tag1,
    input  wire [ROB_W-1:0]         rob_rd_tag2,
    output wire                     rob_rd_ready1,
    output wire                     rob_rd_ready2,
    output wire [`XLEN-1:0]         rob_rd_value1,
    output wire [`XLEN-1:0]         rob_rd_value2,
    // the four buses
    input  wire [`NCDB-1:0]         cdb_valid,
    input  wire [`NCDB*ROB_W-1:0]   cdb_tag,
    input  wire [`NCDB*`XLEN-1:0]   cdb_value,
    // commit
    output wire                     cm_valid,
    output wire [ROB_W-1:0]         cm_tag,
    output wire                     cm_has_rd,
    output wire [`REG_W-1:0]        cm_rd,
    output wire [`XLEN-1:0]         cm_value,
    output wire                     cm_is_store,
    output wire [`XLEN-1:0]         cm_pc,
    // out-of-order completion evidence
    output reg                      ooo_event
);

    reg  [ROB_N-1:0]        valid;
    reg  [ROB_N-1:0]        ready;
    reg  [`KIND_W-1:0]      kind   [0:ROB_N-1];
    reg  [ROB_N-1:0]        has_rd;
    reg  [`REG_W-1:0]       rd     [0:ROB_N-1];
    reg  [`XLEN-1:0]        value  [0:ROB_N-1];
    reg  [`XLEN-1:0]        pc     [0:ROB_N-1];

    reg  [ROB_W-1:0]        head;
    reg  [ROB_W-1:0]        tail;
    reg  [ROB_W:0]          count;

    wire do_alloc  = rob_al_valid & ~rob_full;
    wire do_commit = cm_valid;

    wire [ROB_W-1:0] head_next = (head == ROB_N-1) ? {ROB_W{1'b0}} : head + 1'b1;
    wire [ROB_W-1:0] tail_next = (tail == ROB_N-1) ? {ROB_W{1'b0}} : tail + 1'b1;

    // ---- status and allocate ------------------------------------------------
    assign rob_full   = (count == ROB_N);
    assign rob_empty  = (count == 0);
    assign rob_count  = count;
    assign rob_al_tag = tail;

    // ---- read ports ---------------------------------------------------------
    assign rob_rd_ready1 = valid[rob_rd_tag1] & ready[rob_rd_tag1];
    assign rob_rd_ready2 = valid[rob_rd_tag2] & ready[rob_rd_tag2];
    assign rob_rd_value1 = value[rob_rd_tag1];
    assign rob_rd_value2 = value[rob_rd_tag2];

    // ---- commit (head) ------------------------------------------------------
    assign cm_valid    = valid[head] & ready[head];
    assign cm_tag      = head;
    assign cm_has_rd   = has_rd[head];
    assign cm_rd       = rd[head];
    assign cm_value    = value[head];
    assign cm_is_store = (kind[head] == `KIND_STORE);
    assign cm_pc       = pc[head];

    // ---- ooo_event (D18) ----------------------------------------------------
    integer k;
    always @(*) begin
        ooo_event = 1'b0;
        for (k = 0; k < `NCDB; k = k + 1)
            if (cdb_valid[k] && cdb_tag[k*ROB_W +: ROB_W] != head &&
                valid[head] && !ready[head])
                ooo_event = 1'b1;
    end

    // ---- state --------------------------------------------------------------
    integer i, b;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid  <= {ROB_N{1'b0}};
            ready  <= {ROB_N{1'b0}};
            has_rd <= {ROB_N{1'b0}};
            head   <= {ROB_W{1'b0}};
            tail   <= {ROB_W{1'b0}};
            count  <= {(ROB_W+1){1'b0}};
            for (i = 0; i < ROB_N; i = i + 1) begin
                kind[i]  <= `KIND_VALUE;
                rd[i]    <= {`REG_W{1'b0}};
                value[i] <= {`XLEN{1'b0}};
                pc[i]    <= {`XLEN{1'b0}};
            end
        end else begin
            // complete: one write port per bus, never the same entry twice
            for (b = 0; b < `NCDB; b = b + 1)
                if (cdb_valid[b] && valid[cdb_tag[b*ROB_W +: ROB_W]]) begin
                    ready[cdb_tag[b*ROB_W +: ROB_W]] <= 1'b1;
                    value[cdb_tag[b*ROB_W +: ROB_W]] <= cdb_value[b*`XLEN +: `XLEN];
                end

            // commit frees the head (tail != head unless full, and a full ROB
            // ignores allocation, so commit and allocate never hit one entry)
            if (do_commit) begin
                valid[head] <= 1'b0;
                ready[head] <= 1'b0;
                head        <= head_next;
            end

            if (do_alloc) begin
                valid[tail]  <= 1'b1;
                ready[tail]  <= rob_al_pre;
                kind[tail]   <= rob_al_kind;
                has_rd[tail] <= rob_al_has_rd;
                rd[tail]     <= rob_al_rd;
                value[tail]  <= rob_al_pre ? rob_al_value : {`XLEN{1'b0}};
                pc[tail]     <= rob_al_pc;
                tail         <= tail_next;
            end

            if (do_alloc && !do_commit)      count <= count + 1'b1;
            else if (!do_alloc && do_commit) count <= count - 1'b1;
        end
    end

endmodule
