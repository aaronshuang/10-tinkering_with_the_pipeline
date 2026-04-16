// Reorder Buffer (ROB) — Tomasulo with ROB for in-order commit
// 16-entry circular buffer, dual dispatch, dual commit
// Physical register number is used as the CDB tag (= Tomasulo operand tag)
// Flush-at-commit: mispredicted branch triggers flush when it retires

`timescale 1ns/1ps
module ROB (
    input  clk,
    input  reset,

    // ── DISPATCH (up to 2/cycle, in program order) ─────────────────────────
    input        disp_en0,
    input  [4:0] disp_opcode0,
    input  [4:0] disp_arch_rd0,
    input  [5:0] disp_phys_rd0,
    input [63:0] disp_pc0,
    input        disp_is_branch0,
    input        disp_is_store0,
    output [3:0] disp_tag0,          // ROB index assigned to slot 0

    input        disp_en1,
    input  [4:0] disp_opcode1,
    input  [4:0] disp_arch_rd1,
    input  [5:0] disp_phys_rd1,
    input [63:0] disp_pc1,
    input        disp_is_branch1,
    input        disp_is_store1,
    output [3:0] disp_tag1,          // ROB index assigned to slot 1

    output       disp_full,          // Less than 2 free slots — stall dispatch

    // ── CDB: mark entry done + store result ─────────────────────────────────
    input        cdb_valid,
    input  [3:0] cdb_rob_tag,
    input [63:0] cdb_data,

    // ── BRANCH RESOLUTION (from integer execute stage) ──────────────────────
    input        bres_valid,
    input  [3:0] bres_rob_tag,
    input        bres_mispred,
    input [63:0] bres_tgt,           // Correct branch target

    // ── STORE ADDRESS/DATA UPDATE (from mem execute) ─────────────────────────
    input        su_valid,
    input  [3:0] su_rob_tag,
    input [63:0] su_addr,
    input [63:0] su_data,

    // ── COMMIT PORT 0 (head) ─────────────────────────────────────────────────
    output        cv0,
    output  [4:0] cop0,
    output  [4:0] card0,
    output  [5:0] cprd0,
    output [63:0] cres0,
    output        cbr0,
    output        cstore0,
    output [63:0] csa0, csd0,
    output        cmp0,
    output [63:0] ctgt0,
    input         ca0,               // Commit accept for slot 0

    // ── COMMIT PORT 1 (head+1) ───────────────────────────────────────────────
    output        cv1,
    output  [4:0] cop1,
    output  [4:0] card1,
    output  [5:0] cprd1,
    output [63:0] cres1,
    output        cbr1,
    output        cstore1,
    output [63:0] csa1, csd1,
    output        cmp1,
    output [63:0] ctgt1,
    input         ca1,               // Commit accept for slot 1

    // ── STATUS ────────────────────────────────────────────────────────────────
    output [3:0] head_ptr,
    output [4:0] n_entries,
    output       rob_flush           // Mispredicted branch committing this cycle
);
    localparam N = 16;

    reg [N-1:0] valid_r;
    reg [N-1:0] done_r;
    reg [N-1:0] is_br_r;
    reg [N-1:0] is_store_r;
    reg [N-1:0] mispred_r;

    reg  [4:0] rop   [0:N-1];
    reg  [4:0] rard  [0:N-1];
    reg  [5:0] rprd  [0:N-1];
    reg [63:0] rres  [0:N-1];
    reg [63:0] rpc   [0:N-1];
    reg [63:0] rtgt  [0:N-1];
    reg [63:0] rsa   [0:N-1];
    reg [63:0] rsd   [0:N-1];

    reg [3:0] head_r, tail_r;
    reg [4:0] cnt_r;

    assign head_ptr  = head_r;
    assign n_entries = cnt_r;
    assign disp_full = (cnt_r >= 5'd15);   // keep ≥1 margin for dual dispatch

    assign disp_tag0 = tail_r;
    assign disp_tag1 = tail_r + 4'd1;

    // ── Commit port 0 (head) ─────────────────────────────────────────────────
    wire [3:0] h0 = head_r;
    wire [3:0] h1 = head_r + 4'd1;

    assign cv0    = (cnt_r > 5'd0) && valid_r[h0] && done_r[h0];
    assign cop0   = rop  [h0];
    assign card0  = rard [h0];
    assign cprd0  = rprd [h0];
    assign cres0  = rres [h0];
    assign cbr0   = is_br_r  [h0];
    assign cstore0= is_store_r[h0];
    assign csa0   = rsa  [h0];
    assign csd0   = rsd  [h0];
    assign cmp0   = mispred_r[h0];
    assign ctgt0  = rtgt [h0];

    // ── Commit port 1 (head+1) only when port 0 commits & not mispredict ─────
    assign cv1    = ca0 && !cmp0 && (cnt_r > 5'd1) && valid_r[h1] && done_r[h1];
    assign cop1   = rop  [h1];
    assign card1  = rard [h1];
    assign cprd1  = rprd [h1];
    assign cres1  = rres [h1];
    assign cbr1   = is_br_r  [h1];
    assign cstore1= is_store_r[h1];
    assign csa1   = rsa  [h1];
    assign csd1   = rsd  [h1];
    assign cmp1   = mispred_r[h1];
    assign ctgt1  = rtgt [h1];

    // Flush = mispredicted branch is being committed this cycle
    assign rob_flush = ca0 && cmp0;

    integer j;

    always @(posedge clk) begin
        if (reset) begin
            valid_r  <= 0;
            done_r   <= 0;
            mispred_r<= 0;
            head_r   <= 4'd0;
            tail_r   <= 4'd0;
            cnt_r    <= 5'd0;
        end else if (rob_flush) begin
            // Mispredicted branch commits: retire it, squash everything after
            valid_r           <= 0;
            head_r            <= head_r + 4'd1;   // retire the branch
            tail_r            <= head_r + 4'd1;   // tail = new head (ROB empty after flush)
            cnt_r             <= 5'd0;
        end else begin
            // ── CDB mark done ──────────────────────────────────────────────
            if (cdb_valid) begin
                done_r  [cdb_rob_tag] <= 1'b1;
                rres    [cdb_rob_tag] <= cdb_data;
            end

            // ── Branch resolve ─────────────────────────────────────────────
            if (bres_valid) begin
                done_r   [bres_rob_tag] <= 1'b1;
                mispred_r[bres_rob_tag] <= bres_mispred;
                rtgt     [bres_rob_tag] <= bres_tgt;
            end

            // ── Store update ───────────────────────────────────────────────
            if (su_valid) begin
                rsa[su_rob_tag] <= su_addr;
                rsd[su_rob_tag] <= su_data;
                // Mark done for stores when address+data known
                is_store_r[su_rob_tag] <= 1'b1;
                done_r    [su_rob_tag] <= 1'b1;
            end

            // ── Dispatch ───────────────────────────────────────────────────
            if (disp_en0 && !disp_full) begin
                valid_r   [tail_r]   <= 1'b1;
                done_r    [tail_r]   <= 1'b0;
                mispred_r [tail_r]   <= 1'b0;
                is_store_r[tail_r]   <= 1'b0;
                rop  [tail_r]        <= disp_opcode0;
                rard [tail_r]        <= disp_arch_rd0;
                rprd [tail_r]        <= disp_phys_rd0;
                rpc  [tail_r]        <= disp_pc0;
                is_br_r[tail_r]      <= disp_is_branch0;
            end
            if (disp_en1 && !disp_full) begin
                valid_r   [tail_r+1] <= 1'b1;
                done_r    [tail_r+1] <= 1'b0;
                mispred_r [tail_r+1] <= 1'b0;
                is_store_r[tail_r+1] <= 1'b0;
                rop  [tail_r+1]      <= disp_opcode1;
                rard [tail_r+1]      <= disp_arch_rd1;
                rprd [tail_r+1]      <= disp_phys_rd1;
                rpc  [tail_r+1]      <= disp_pc1;
                is_br_r[tail_r+1]    <= disp_is_branch1;
            end
            case ({disp_en0 && !disp_full, disp_en1 && !disp_full})
                2'b10:   tail_r <= tail_r + 4'd1;
                2'b11:   tail_r <= tail_r + 4'd2;
                default: ;
            endcase

            // ── Commit ────────────────────────────────────────────────────
            if (ca1) begin
                // Dual commit
                valid_r[head_r]        <= 1'b0;
                valid_r[head_r + 4'd1] <= 1'b0;
                head_r <= head_r + 4'd2;
            end else if (ca0) begin
                // Single commit
                valid_r[head_r] <= 1'b0;
                head_r <= head_r + 4'd1;
            end

            // ── Count ─────────────────────────────────────────────────────
            cnt_r <= cnt_r
                + ((disp_en0 && !disp_full) ? 5'd1 : 5'd0)
                + ((disp_en1 && !disp_full) ? 5'd1 : 5'd0)
                - (ca1 ? 5'd2 : ca0 ? 5'd1 : 5'd0);
        end
    end
endmodule
