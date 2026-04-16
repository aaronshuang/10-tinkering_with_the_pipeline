// Reservation Station for Memory Operations (Loads/Stores)
// 4-entry circular buffer to maintain program order for memory consistency
// Issue logic:
// - Loads: Ready when Vj (base) is ready.
// - Stores: Ready when Vj (base) and Vk (data) are ready.

`timescale 1ns/1ps
module RS_Mem (
    input  clk,
    input  reset,
    input  flush,

    // ── DISPATCH (1/cycle) ──────────────────────────────────────────────────
    input        disp_en,
    input  [4:0] disp_opcode,
    input  [5:0] disp_phys_rd,
    input  [3:0] disp_rob_tag,
    input [63:0] disp_Vj,       // Base register value
    input  [5:0] disp_Qj,       // Base register tag
    input [63:0] disp_Vk,       // Store data value
    input  [5:0] disp_Qk,       // Store data tag
    input [11:0] disp_imm,
    output       disp_full,

    // ── CDB SNOOP ──────────────────────────────────────────────────────────
    input        cdb_valid,
    input  [5:0] cdb_tag,
    input [63:0] cdb_data,

    // ── ISSUE OUTPUT ────────────────────────────────────────────────────────
    output        issue_valid,
    output  [4:0] issue_opcode,
    output  [5:0] issue_phys_rd,
    output  [3:0] issue_rob_tag,
    output [63:0] issue_Vj,     // Base
    output [63:0] issue_Vk,     // Data (for stores)
    output [11:0] issue_imm,
    input         issue_accept
);
    reg [3:0]  valid_r;
    reg  [4:0] e_op  [0:3];
    reg  [5:0] e_prd [0:3];
    reg  [3:0] e_rt  [0:3];
    reg [63:0] e_Vj  [0:3];
    reg  [5:0] e_Qj  [0:3];
    reg [63:0] e_Vk  [0:3];
    reg  [5:0] e_Qk  [0:3];
    reg [11:0] e_imm [0:3];

    // Maintain a simple head/tail to issue memory ops in order (easiest for consistency)
    reg [1:0] head_r, tail_r;
    reg [2:0] cnt_r;

    assign disp_full = (cnt_r == 3'd4);

    // Live CDB bypass for issue ready check
    wire Qj_rdy_h = (e_Qj[head_r] == 6'd0) || (cdb_valid && cdb_tag == e_Qj[head_r]);
    wire Qk_rdy_h = (e_Qk[head_r] == 6'd0) || (cdb_valid && cdb_tag == e_Qk[head_r]);

    // Stores need both Vj and Vk; Loads only need Vj
    wire is_store_h = (e_op[head_r] == 5'd13); // OP_STORE (verify in tinker.sv)
    wire ready_h = valid_r[head_r] && Qj_rdy_h && (!is_store_h || Qk_rdy_h);

    assign issue_valid   = ready_h;
    assign issue_opcode  = e_op  [head_r];
    assign issue_phys_rd = e_prd [head_r];
    assign issue_rob_tag = e_rt  [head_r];
    assign issue_Vj      = (cdb_valid && cdb_tag == e_Qj[head_r] && e_Qj[head_r] != 0) ? cdb_data : e_Vj[head_r];
    assign issue_Vk      = (cdb_valid && cdb_tag == e_Qk[head_r] && e_Qk[head_r] != 0) ? cdb_data : e_Vk[head_r];
    assign issue_imm     = e_imm [head_r];

    integer i;
    always @(posedge clk) begin
        if (reset || flush) begin
            valid_r <= 4'b0;
            head_r  <= 2'd0;
            tail_r  <= 2'd0;
            cnt_r   <= 3'd0;
        end else begin
            // ── CDB SNOOP ──────────────────────────────────────────────────
            if (cdb_valid) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (valid_r[i]) begin
                        if (e_Qj[i] != 0 && cdb_tag == e_Qj[i]) begin
                            e_Vj[i] <= cdb_data; e_Qj[i] <= 6'd0;
                        end
                        if (e_Qk[i] != 0 && cdb_tag == e_Qk[i]) begin
                            e_Vk[i] <= cdb_data; e_Qk[i] <= 6'd0;
                        end
                    end
                end
            end

            // ── ISSUE ─────────────────────────────────────────────────────
            if (issue_valid && issue_accept) begin
                valid_r[head_r] <= 1'b0;
                head_r <= head_r + 2'd1;
                cnt_r  <= cnt_r - 3'd1;
            end

            // ── DISPATCH ──────────────────────────────────────────────────
            if (disp_en && !disp_full) begin
                valid_r[tail_r] <= 1'b1;
                e_op   [tail_r] <= disp_opcode;
                e_prd  [tail_r] <= disp_phys_rd;
                e_rt   [tail_r] <= disp_rob_tag;
                e_imm  [tail_r] <= disp_imm;
                
                // Snoop CDB at dispatch
                e_Vj   [tail_r] <= (cdb_valid && cdb_tag == disp_Qj && disp_Qj != 0) ? cdb_data : disp_Vj;
                e_Qj   [tail_r] <= (cdb_valid && cdb_tag == disp_Qj && disp_Qj != 0) ? 6'd0 : disp_Qj;
                e_Vk   [tail_r] <= (cdb_valid && cdb_tag == disp_Qk && disp_Qk != 0) ? cdb_data : disp_Vk;
                e_Qk   [tail_r] <= (cdb_valid && cdb_tag == disp_Qk && disp_Qk != 0) ? 6'd0 : disp_Qk;

                tail_r <= tail_r + 2'd1;
                // Avoid double counting if issue and dispatch happen at same time
                cnt_r  <= cnt_r + ((issue_valid && issue_accept) ? 3'd0 : 3'd1);
            end else if (issue_valid && issue_accept) begin
                // Just issue, no dispatch
                // Already handled head_r and cnt_r above
            end
        end
    end
endmodule
