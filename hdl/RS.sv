// Generic 4-entry Reservation Station for Tomasulo OOO
// CDB tag = physical register number (6-bit)
// Vj/Qj = source A (ALU input A, or rs, or rd-as-src depending on opcode)
// Vk/Qk = source B (ALU input B, or rt)
// Vrd/Qrd = branch target source (rd for branches); unused by non-branch ops
// issue_accept = 1 means the connected FU consumed the issued instruction

`timescale 1ns/1ps
module RS (
    input  clk,
    input  reset,
    input  flush,

    // ── DISPATCH (1/cycle) ──────────────────────────────────────────────────
    input        disp_en,
    input  [4:0] disp_opcode,
    input  [5:0] disp_phys_rd,
    input  [3:0] disp_rob_tag,
    input [63:0] disp_Vj,
    input  [5:0] disp_Qj,    // 0 = Vj is valid
    input [63:0] disp_Vk,
    input  [5:0] disp_Qk,    // 0 = Vk is valid (ignore when use_imm=1)
    input [11:0] disp_imm,
    input        disp_use_imm,
    input [63:0] disp_Vrd,   // branch target source value
    input  [5:0] disp_Qrd,   // branch target source tag (0 = Vrd ready)
    input [63:0] disp_pc,
    output       disp_full,   // All 4 slots occupied

    // ── CDB SNOOP ──────────────────────────────────────────────────────────
    input        cdb_valid,
    input  [5:0] cdb_tag,
    input [63:0] cdb_data,

    // ── ISSUE OUTPUT ────────────────────────────────────────────────────────
    output        issue_valid,
    output  [4:0] issue_opcode,
    output  [5:0] issue_phys_rd,
    output  [3:0] issue_rob_tag,
    output [63:0] issue_Vj,
    output [63:0] issue_Vk,
    output  [5:0] issue_Qrd_out,  // Expose Qrd so caller can gate on it
    output [63:0] issue_Vrd,
    output [11:0] issue_imm,
    output        issue_use_imm,
    output [63:0] issue_pc,
    input         issue_accept   // FU accepted this cycle; clear the slot
);
    // ── 4 RS entries ────────────────────────────────────────────────────────
    reg [3:0]  valid_r;
    reg  [4:0] e_op  [0:3];
    reg  [5:0] e_prd [0:3];
    reg  [3:0] e_rt  [0:3];   // rob_tag
    reg [63:0] e_Vj  [0:3];
    reg  [5:0] e_Qj  [0:3];
    reg [63:0] e_Vk  [0:3];
    reg  [5:0] e_Qk  [0:3];
    reg [11:0] e_imm [0:3];
    reg  [3:0] e_uimm;
    reg [63:0] e_Vrd [0:3];
    reg  [5:0] e_Qrd [0:3];
    reg [63:0] e_pc  [0:3];

    // ── Effective values: live CDB bypass ────────────────────────────────────
    wire [63:0] Vj_eff  [0:3];
    wire [63:0] Vk_eff  [0:3];
    wire [63:0] Vrd_eff [0:3];
    wire        Qj_rdy  [0:3];
    wire        Qk_rdy  [0:3];
    wire        Qrd_rdy [0:3];

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : eff
            assign Qj_rdy [g] = (e_Qj [g] == 6'd0)
                              || (cdb_valid && cdb_tag == e_Qj [g]);
            assign Qk_rdy [g] = (e_Qk [g] == 6'd0)
                              || (cdb_valid && cdb_tag == e_Qk [g])
                              || e_uimm[g];
            assign Qrd_rdy[g] = (e_Qrd[g] == 6'd0)
                              || (cdb_valid && cdb_tag == e_Qrd[g]);

            assign Vj_eff [g] = (cdb_valid && cdb_tag == e_Qj [g] && e_Qj [g] != 0)
                                ? cdb_data : e_Vj [g];
            assign Vk_eff [g] = (cdb_valid && cdb_tag == e_Qk [g] && e_Qk [g] != 0)
                                ? cdb_data : e_Vk [g];
            assign Vrd_eff[g] = (cdb_valid && cdb_tag == e_Qrd[g] && e_Qrd[g] != 0)
                                ? cdb_data : e_Vrd[g];
        end
    endgenerate

    // ── Ready: all sources available ─────────────────────────────────────────
    wire [3:0] entry_ready;
    assign entry_ready[0] = valid_r[0] && Qj_rdy[0] && Qk_rdy[0] && Qrd_rdy[0];
    assign entry_ready[1] = valid_r[1] && Qj_rdy[1] && Qk_rdy[1] && Qrd_rdy[1];
    assign entry_ready[2] = valid_r[2] && Qj_rdy[2] && Qk_rdy[2] && Qrd_rdy[2];
    assign entry_ready[3] = valid_r[3] && Qj_rdy[3] && Qk_rdy[3] && Qrd_rdy[3];

    // ── Issue select: lowest-index (oldest) ready entry ──────────────────────
    wire        any_ready  = |entry_ready;
    wire [1:0]  issue_sel  = entry_ready[0] ? 2'd0 :
                             entry_ready[1] ? 2'd1 :
                             entry_ready[2] ? 2'd2 : 2'd3;

    assign issue_valid    = any_ready;
    assign issue_opcode   = e_op  [issue_sel];
    assign issue_phys_rd  = e_prd [issue_sel];
    assign issue_rob_tag  = e_rt  [issue_sel];
    assign issue_Vj       = Vj_eff [issue_sel];
    assign issue_Vk       = Vk_eff [issue_sel];
    assign issue_Qrd_out  = e_Qrd [issue_sel];
    assign issue_Vrd      = Vrd_eff[issue_sel];
    assign issue_imm      = e_imm [issue_sel];
    assign issue_use_imm  = e_uimm[issue_sel];
    assign issue_pc       = e_pc  [issue_sel];

    // ── Free-slot selection: lowest index free ───────────────────────────────
    wire [3:0]  free_mask = ~valid_r;
    wire        any_free  = |free_mask;
    wire [1:0]  free_sel  = free_mask[0] ? 2'd0 :
                            free_mask[1] ? 2'd1 :
                            free_mask[2] ? 2'd2 : 2'd3;
    assign disp_full = !any_free;

    integer i;
    always @(posedge clk) begin
        if (reset || flush) begin
            valid_r <= 4'b0;
        end else begin
            // ── CDB capture (update waiting tags to values) ────────────────
            if (cdb_valid) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (valid_r[i]) begin
                        if (e_Qj [i] != 0 && cdb_tag == e_Qj [i]) begin
                            e_Vj[i] <= cdb_data; e_Qj[i] <= 6'd0;
                        end
                        if (e_Qk [i] != 0 && cdb_tag == e_Qk [i]) begin
                            e_Vk[i] <= cdb_data; e_Qk[i] <= 6'd0;
                        end
                        if (e_Qrd[i] != 0 && cdb_tag == e_Qrd[i]) begin
                            e_Vrd[i] <= cdb_data; e_Qrd[i] <= 6'd0;
                        end
                    end
                end
            end

            // ── Issue: clear issued slot ──────────────────────────────────
            if (issue_valid && issue_accept) begin
                valid_r[issue_sel] <= 1'b0;
            end

            // ── Dispatch: fill a free slot ────────────────────────────────
            if (disp_en && any_free) begin
                valid_r [free_sel] <= 1'b1;
                e_op    [free_sel] <= disp_opcode;
                e_prd   [free_sel] <= disp_phys_rd;
                e_rt    [free_sel] <= disp_rob_tag;
                e_imm   [free_sel] <= disp_imm;
                e_uimm  [free_sel] <= disp_use_imm;
                e_pc    [free_sel] <= disp_pc;
                // Apply live CDB snoop at dispatch time
                e_Vj    [free_sel] <= (cdb_valid && cdb_tag == disp_Qj && disp_Qj != 0)
                                      ? cdb_data : disp_Vj;
                e_Qj    [free_sel] <= (cdb_valid && cdb_tag == disp_Qj && disp_Qj != 0)
                                      ? 6'd0 : disp_Qj;
                e_Vk    [free_sel] <= (cdb_valid && cdb_tag == disp_Qk && disp_Qk != 0)
                                      ? cdb_data : disp_Vk;
                e_Qk    [free_sel] <= (cdb_valid && cdb_tag == disp_Qk && disp_Qk != 0)
                                      ? 6'd0 : disp_Qk;
                e_Vrd   [free_sel] <= (cdb_valid && cdb_tag == disp_Qrd && disp_Qrd != 0)
                                      ? cdb_data : disp_Vrd;
                e_Qrd   [free_sel] <= (cdb_valid && cdb_tag == disp_Qrd && disp_Qrd != 0)
                                      ? 6'd0 : disp_Qrd;
            end
        end
    end
endmodule
