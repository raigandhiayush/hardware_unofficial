`timescale 1ns/1ps
// l1_dcache.v - L1 data cache between the LSU and data_mem / MMIO (TOMA-RV)
//
// Organisation (parameters, defaults from ooo_defs.vh):
//   WAYS 1 or 2 (2: one LRU bit per set), SETS sets per way (power of 2, >= 2),
//   WORDS 32-bit words per line (4 or 8), WB = 1 write-back / write-allocate
//   with a dirty bit per line, WB = 0 write-through / no-write-allocate.
//   Tags cover byte-address bits [MEM_AW-1:0] only, the bits data_mem decodes,
//   so addresses that alias in data_mem (e.g. 0x0000_0100 and 0xFFFF_F100)
//   also share one cache line and the cached system sees the same memory.
//
// LSU side (one request per cycle, accepted when req_valid & ~stall):
//   * stall is registered (state != IDLE): constant for the whole cycle.
//   * Load hit: tag compare and data read in the request cycle c, the word is
//     registered and resp_ready = 1 in c+1 (1-cycle hit latency, as data_mem).
//   * Load miss: stall from c+1; [WRITEBACK: WORDS writes of the dirty victim]
//     REFILL: WORDS reads, one per cycle (data_mem returns data next cycle);
//     resp_ready = 1 in the cycle after the last word arrives, and stall is
//     already 0 in that cycle.
//   * Stores arrive only in their ROB commit cycle (the LSU's st_commit), so the
//     cache never holds speculative data. Store hit: bytes merged into the line
//     in c (WB: line dirty; WT: also written to data_mem in c). Store miss: WT
//     writes data_mem only; WB allocates the line, merges on refill, sets dirty.
//     A store has no response.
//   * MMIO (addr[31:28] = 4'h1) is never cached: a load is passed to the memory
//     port in c and returned from mem_rdata in c+1 (state MMIO_PASS, stall = 1);
//     a store is passed to the memory port in c.
//   * The LSU must not send a request while stall = 1 (a simulation check
//     prints TEST_FAIL if it does); a store at commit cannot wait, the LSU
//     guarantees the cache is idle by starting a store's SR only when stall = 0.
//
// Memory side: the data_mem protocol (read data one cycle after mem_re, write
// in the cycle of mem_we). Line fills and write-backs use addresses with bits
// [31:MEM_AW] = 0; pass-through requests keep the LSU's full address.
//
// Events (one-cycle pulses, for perf_counters): ev_access per accepted
// cacheable request, ev_hit / ev_miss split it, ev_stall = stall.
//
// reset_n: active low, asynchronous; clears valid, dirty, LRU and the FSM.
// Data and tag arrays are not reset (only read behind a valid bit).

`include "ooo_defs.vh"

module l1_dcache #(
    parameter WAYS   = `DC_WAYS,
    parameter SETS   = `DC_SETS,
    parameter WORDS  = `DC_WORDS,
    parameter WB     = `DC_WB,
    parameter MEM_AW = `DC_MEM_AW
) (
    input  wire                 clk,
    input  wire                 reset_n,
    // LSU side
    input  wire                 req_valid,
    input  wire                 req_we,
    input  wire [`XLEN-1:0]     req_addr,
    input  wire [`XLEN-1:0]     req_wdata,
    input  wire [3:0]           req_byte_en,
    output wire                 stall,
    output wire                 resp_ready,
    output wire [`XLEN-1:0]     resp_data,
    // memory side (data_mem and the MMIO decode in the board top)
    output reg                  mem_re,
    output reg  [`XLEN-1:0]     mem_raddr,
    input  wire [`XLEN-1:0]     mem_rdata,
    input  wire                 mem_read_valid,  // 0: a read is outstanding
    input  wire                 mem_write_valid, // 0: the write buffer is full
    output reg                  mem_we,
    output reg  [`XLEN-1:0]     mem_waddr,
    output reg  [`XLEN-1:0]     mem_wdata,
    output reg  [3:0]           mem_wstrb,
    // events
    output wire                 ev_access,
    output wire                 ev_hit,
    output wire                 ev_miss,
    output wire                 ev_stall
);

    localparam OFF_W = $clog2(WORDS);
    localparam IDX_W = $clog2(SETS);
    localparam TAG_W = MEM_AW - 2 - OFF_W - IDX_W;
    localparam LINES = WAYS * SETS;

    localparam [1:0] S_IDLE      = 2'd0,    // compare tag; accept a request
                     S_WRITEBACK = 2'd1,    // write the dirty victim line back
                     S_REFILL    = 2'd2,    // allocate: read the new line
                     S_MMIO      = 2'd3;    // MMIO load: data arrives this cycle

    // ---- arrays ------------------------------------------------------------------
    reg  [LINES-1:0]        valid;
    reg  [LINES-1:0]        dirty;
    reg  [TAG_W-1:0]        tags [0:LINES-1];
    reg  [`XLEN-1:0]        data [0:LINES*WORDS-1];
    reg  [SETS-1:0]         lru;                    // way to replace next (WAYS = 2)

    // ---- FSM and the request being serviced ---------------------------------------
    reg  [1:0]              state;
    reg  [OFF_W:0]          cnt;                    // words issued (write-back / refill)
    reg                     rd_pend;                // a refill read returns this cycle
    reg  [OFF_W-1:0]        rd_idx;                 // ... for this word
    reg                     q_we;
    reg  [TAG_W-1:0]        q_tag;
    reg  [IDX_W-1:0]        q_set;
    reg  [OFF_W-1:0]        q_word;
    reg  [`XLEN-1:0]        q_wdata;
    reg  [3:0]              q_be;
    reg                     q_way;
    reg                     resp_q;
    reg  [`XLEN-1:0]        resp_data_q;

    function [`XLEN-1:0] merge(input [`XLEN-1:0] old, input [`XLEN-1:0] nw, input [3:0] be);
        merge = {be[3] ? nw[31:24] : old[31:24], be[2] ? nw[23:16] : old[23:16],
                 be[1] ? nw[15: 8] : old[15: 8], be[0] ? nw[ 7: 0] : old[ 7: 0]};
    endfunction

    // ---- request decode and lookup (combinational, request cycle) ------------------
    wire [OFF_W-1:0]  r_word = req_addr[2 +: OFF_W];
    wire [IDX_W-1:0]  r_set  = req_addr[2+OFF_W +: IDX_W];
    wire [TAG_W-1:0]  r_tag  = req_addr[2+OFF_W+IDX_W +: TAG_W];
    wire              r_mmio = (req_addr[31:28] == 4'h1);

    assign stall  = (state != S_IDLE) | ~mem_write_valid;
    wire   accept = req_valid & ~stall;

    reg               hit;
    reg               hit_way;
    integer w;
    always @(*) begin
        hit     = 1'b0;
        hit_way = 1'b0;
        for (w = 0; w < WAYS; w = w + 1)
            if (valid[w*SETS + r_set] && tags[w*SETS + r_set] == r_tag) begin
                hit     = 1'b1;
                hit_way = w;
            end
    end

    // victim: an invalid way first, else the LRU way (a continuous assignment:
    // with WAYS = 1 it is the constant 0, which an always @(*) would never evaluate)
    wire              vic_way = (WAYS == 1)          ? 1'b0 :
                                !valid[r_set]        ? 1'b0 :
                                !valid[SETS + r_set] ? 1'b1 : lru[r_set];

    wire [31:0] h_line = hit_way * SETS + r_set;
    wire [31:0] h_idx  = h_line * WORDS + r_word;
    wire [31:0] v_line = vic_way * SETS + r_set;
    wire [31:0] q_line = q_way * SETS + q_set;

    assign ev_access = accept & ~r_mmio;
    assign ev_hit    = ev_access &  hit;
    assign ev_miss   = ev_access & ~hit;
    assign ev_stall  = stall;

    assign resp_ready = resp_q | (state == S_MMIO);
    assign resp_data  = (state == S_MMIO) ? mem_rdata : resp_data_q;

    // ---- memory port -------------------------------------------------------------
    always @(*) begin
        mem_re    = 1'b0;
        mem_raddr = req_addr;
        mem_we    = 1'b0;
        mem_waddr = req_addr;
        mem_wdata = req_wdata;
        mem_wstrb = req_byte_en;
        case (state)
            S_IDLE:
                if (accept) begin
                    if (r_mmio)                    // uncached pass-through
                        if (req_we) mem_we = 1'b1;
                        else        mem_re = 1'b1;
                    else if (req_we && !WB)        // write-through, hit or miss
                        mem_we = 1'b1;
                end
            S_WRITEBACK: begin
                mem_we    = mem_write_valid;
                mem_waddr = {{(`XLEN-MEM_AW){1'b0}}, tags[q_line], q_set, cnt[OFF_W-1:0], 2'b00};
                mem_wdata = data[q_line*WORDS + cnt[OFF_W-1:0]];
                mem_wstrb = 4'b1111;
            end
            S_REFILL: begin
                mem_re    = (cnt < WORDS) & mem_read_valid;
                mem_raddr = {{(`XLEN-MEM_AW){1'b0}}, q_tag, q_set, cnt[OFF_W-1:0], 2'b00};
            end
            default: ;                             // S_MMIO: data comes back
        endcase
    end

    // ---- state ---------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid       <= {LINES{1'b0}};
            dirty       <= {LINES{1'b0}};
            lru         <= {SETS{1'b0}};
            state       <= S_IDLE;
            cnt         <= {(OFF_W+1){1'b0}};
            rd_pend     <= 1'b0;
            rd_idx      <= {OFF_W{1'b0}};
            q_we        <= 1'b0;
            q_tag       <= {TAG_W{1'b0}};
            q_set       <= {IDX_W{1'b0}};
            q_word      <= {OFF_W{1'b0}};
            q_wdata     <= {`XLEN{1'b0}};
            q_be        <= 4'd0;
            q_way       <= 1'b0;
            resp_q      <= 1'b0;
            resp_data_q <= {`XLEN{1'b0}};
        end else begin
            resp_q <= 1'b0;
            case (state)
                S_IDLE:
                    if (accept) begin
                        if (r_mmio) begin
                            if (!req_we) state <= S_MMIO;
                        end else if (hit) begin
                            if (req_we) begin
                                data[h_idx] <= merge(data[h_idx], req_wdata, req_byte_en);
                                if (WB) dirty[h_line] <= 1'b1;
                            end else begin
                                resp_q      <= 1'b1;
                                resp_data_q <= data[h_idx];
                            end
                            if (WAYS > 1) lru[r_set] <= ~hit_way;
                        end else if (!(req_we && !WB)) begin
                            // load miss, or store miss with write-allocate
                            q_we    <= req_we;
                            q_tag   <= r_tag;
                            q_set   <= r_set;
                            q_word  <= r_word;
                            q_wdata <= req_wdata;
                            q_be    <= req_byte_en;
                            q_way   <= vic_way;
                            cnt     <= {(OFF_W+1){1'b0}};
                            rd_pend <= 1'b0;
                            valid[v_line] <= 1'b0;   // the tag stays for the write-back
                            state   <= (WB && valid[v_line] && dirty[v_line]) ? S_WRITEBACK : S_REFILL;
                        end
                        // write-through store miss: memory only (no allocate)
                    end
                S_WRITEBACK: if (mem_write_valid) begin
                    if (cnt == WORDS-1) begin
                        cnt   <= {(OFF_W+1){1'b0}};
                        state <= S_REFILL;
                    end else
                        cnt <= cnt + 1'b1;
                end
                S_REFILL: begin
                    if (mem_re) begin
                        cnt    <= cnt + 1'b1;
                        rd_idx <= cnt[OFF_W-1:0];
                    end
                    if (mem_re) rd_pend <= 1'b1;
                    else if (mem_read_valid) rd_pend <= 1'b0;
                    if (rd_pend && mem_read_valid) begin
                        data[q_line*WORDS + rd_idx] <= (q_we && rd_idx == q_word)
                                                       ? merge(mem_rdata, q_wdata, q_be) : mem_rdata;
                        if (rd_idx == q_word) resp_data_q <= mem_rdata;
                        if (rd_idx == WORDS-1) begin
                            tags[q_line]  <= q_tag;
                            valid[q_line] <= 1'b1;
                            dirty[q_line] <= q_we;   // a write-allocated store dirties the line
                            if (WAYS > 1) lru[q_set] <= ~q_way;
                            resp_q  <= ~q_we;
                            rd_pend <= 1'b0;
                            cnt     <= {(OFF_W+1){1'b0}};
                            state   <= S_IDLE;
                        end
                    end
                end
                default: state <= S_IDLE;            // S_MMIO: response this cycle
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk)
        if (reset_n && req_valid === 1'b1 && stall === 1'b1)
            $display("TEST_FAIL l1_dcache protocol: request while stall = 1 (t=%0t, addr=%h, we=%b)",
                     $time, req_addr, req_we);
    // synthesis translate_on

endmodule
