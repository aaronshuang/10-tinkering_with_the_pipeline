`include "hdl/instruction_decoder.sv"
`include "hdl/register_file.sv"
`include "hdl/ALU.sv"
`include "hdl/FPU.sv"
`include "hdl/memory.sv"
`include "hdl/ROB.sv"
`include "hdl/RS.sv"
`include "hdl/RS_Mem.sv"

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
    // ── CONSTANTS ───────────────────────────────────────────────────────────
    localparam [4:0] OP_AND    = 5'h00;
    localparam [4:0] OP_OR     = 5'h01;
    localparam [4:0] OP_XOR    = 5'h02;
    localparam [4:0] OP_NOT    = 5'h03;
    localparam [4:0] OP_SHFTR  = 5'h04;
    localparam [4:0] OP_SHFTRI = 5'h05;
    localparam [4:0] OP_SHFTL  = 5'h06;
    localparam [4:0] OP_SHFTLI = 5'h07;
    localparam [4:0] OP_BR     = 5'h08;
    localparam [4:0] OP_BRR_R  = 5'h09;
    localparam [4:0] OP_BRR_L  = 5'h0A;
    localparam [4:0] OP_BRNZ   = 5'h0B;
    localparam [4:0] OP_CALL   = 5'h0C;
    localparam [4:0] OP_RET    = 5'h0D;
    localparam [4:0] OP_BRGT   = 5'h0E;
    localparam [4:0] OP_PRIV   = 5'h0F;
    localparam [4:0] OP_MOV_ML = 5'h10;
    localparam [4:0] OP_MOV_RR = 5'h11;
    localparam [4:0] OP_MOV_L  = 5'h12;
    localparam [4:0] OP_MOV_SM = 5'h13;
    localparam [4:0] OP_ADDF   = 5'h14;
    localparam [4:0] OP_SUBF   = 5'h15;
    localparam [4:0] OP_MULF   = 5'h16;
    localparam [4:0] OP_DIVF   = 5'h17;
    localparam [4:0] OP_ADD    = 5'h18;
    localparam [4:0] OP_ADDI   = 5'h19;
    localparam [4:0] OP_SUB    = 5'h1A;
    localparam [4:0] OP_SUBI   = 5'h1B;
    localparam [4:0] OP_MUL    = 5'h1C;
    localparam [4:0] OP_DIV    = 5'h1D;

    // ── FUNCTIONS ───────────────────────────────────────────────────────────
    function writes_register;
        input [4:0] op;
        begin
            case (op)
                OP_AND, OP_OR, OP_XOR, OP_NOT,
                OP_SHFTR, OP_SHFTRI, OP_SHFTL, OP_SHFTLI,
                OP_MOV_ML, OP_MOV_RR, OP_MOV_L,
                OP_ADDF, OP_SUBF, OP_MULF, OP_DIVF,
                OP_ADD, OP_ADDI, OP_SUB, OP_SUBI, OP_MUL, OP_DIV:
                    writes_register = 1'b1;
                default: writes_register = 1'b0;
            endcase
        end
    endfunction

    function same_packet_raw;
        input [4:0] op0, rd0, op1, rs1, rt1, rd1_src;
        begin
            same_packet_raw = writes_register(op0) &&
                              ((rs1 == rd0) || (rt1 == rd0) || (rd1_src == rd0));
        end
    endfunction

    function [63:0] extend_imm;
        input [4:0] op; input [11:0] value;
        begin if (op == OP_ADDI || op == OP_SUBI) extend_imm = {52'b0, value}; else extend_imm = {{52{value[11]}}, value}; end
    endfunction

    // ── ALL DECLARATIONS ─────────────────────────────────────────────────────
    reg [63:0] pc;
    integer i, alloc_i;
    reg halt_pending;
    integer debug_cycles;

    reg [5:0] rat [0:31];
    reg [5:0] amt [0:31];
    reg [31:0] temp_free;
    reg [63:0] phys_busy;

    wire rob_full, rob_flush;
    wire [3:0] rob_tag0, rob_tag1;
    wire rob_cv0, rob_cv1, rob_cbr0, rob_cbr1, rob_cstore0, rob_cstore1, rob_cmp0, rob_cmp1;
    wire [4:0] rob_cop0, rob_cop1, rob_card0, rob_card1;
    wire [5:0] rob_cprd0, rob_cprd1;
    wire [63:0] rob_cres0, rob_cres1, rob_csa0, rob_csd0, rob_csa1, rob_csd1, rob_ctgt0, rob_ctgt1;
    wire [4:0] rob_n_entries;

    reg cdb_valid;
    reg [5:0] cdb_tag;
    reg [63:0] cdb_data;
    reg [3:0] cdb_rob_tag;

    reg cdb_accept_fpu0, cdb_accept_fpu1, cdb_accept_alu, cdb_accept_md, cdb_accept_load;

    wire alu_issue_valid, alu_ready, alu_done, fpu0_issue_valid, fpu0_ready, fpu0_done, fpu1_issue_valid, fpu1_ready, fpu1_done, muldiv_issue_valid, muldiv_ready, muldiv_done, load_issue_valid, load_ready, load_done;
    wire [4:0] alu_op_issued, fpu0_op_issued, fpu1_op_issued, muldiv_op_issued, opcode_mem_issued;
    wire [4:0] alu_op_out, fpu0_op_out, fpu1_op_out, muldiv_op_out;
    wire [5:0] alu_prd_in, fpu0_prd_in, fpu1_prd_in, muldiv_prd_in, load_prd;
    wire [5:0] alu_prd_out, fpu0_prd_out, fpu1_prd_out, muldiv_prd_out;
    wire [3:0] alu_rt_in, fpu0_rt_in, fpu1_rt_in, muldiv_rt_in, load_rt;
    wire [3:0] alu_rt_out, fpu0_rt_out, fpu1_rt_out, muldiv_rt_out;
    wire [63:0] alu_Vj, alu_Vk, alu_Vrd, alu_res_dir, alu_pc_iss, fpu0_Vj, fpu0_Vk, fpu0_res, fpu1_Vj, fpu1_Vk, fpu1_res, muldiv_Vj, muldiv_Vk, muldiv_res_dir, load_Vj, load_Vk, load_res, load_addr;
    wire [63:0] alu_pc_out, fpu0_pc_out, fpu1_pc_out, muldiv_pc_out;
    wire [11:0] alu_imm, load_imm;
    wire alu_uimm;
    wire [5:0] alu_Qrd_tag;

    wire [63:0] rs_val, rt_val, rd_val, rs1_val, rt1_val, rd1_val, r31_val;
    reg [31:0] if_id_instr, if_id_instr1; reg [63:0] if_id_pc, if_id_pc1; reg if_id_valid, if_id_valid1;
    wire [4:0] opcode, rd, rs, rt, opcode1, rd1, rs1, rt1; wire [11:0] imm, imm1; wire use_imm, is_br, use_imm1, is_br1;
    
    reg alloc0_ok, alloc1_ok; reg [5:0] alloc_phys0, alloc_phys1; reg [31:0] tf_s;
    wire rs_int_full, rs_fpu0_full, rs_fpu1_full, rs_md_full, rs_mem_full;
    wire [5:0] f_idx0; wire [51:0] f_tag0; reg [1:0] bht [0:63]; reg [63:0] btb_tgt [0:63]; reg [51:0] btb_tag [0:63]; reg [63:0] btb_v;
    wire btb_hit0, dec_pf, dec_pair;
    reg br_mispred; reg [63:0] br_corr_tgt;

    wire is_f0, is_f1, is_m0, is_m1, is_md0, is_md1, is_i0, is_i1, disp_en0, disp_en1;
    wire disp_en_int, disp_en_fpu0, disp_en_fpu1, disp_en_md, disp_en_mem;

    wire [4:0] disp_int_op; wire [5:0] disp_int_prd; wire [3:0] disp_int_rt; wire [63:0] disp_int_Vj; wire [5:0] disp_int_Qj; wire [63:0] disp_int_Vk; wire [5:0] disp_int_Qk; wire [63:0] disp_int_Vrd; wire [5:0] disp_int_Qrd; wire [11:0] disp_int_imm; wire disp_int_uimm; wire [63:0] disp_int_pc;
    wire [4:0] disp_fpu0_op; wire [5:0] disp_fpu0_prd; wire [3:0] disp_fpu0_rt; wire [63:0] disp_fpu0_Vj; wire [5:0] disp_fpu0_Qj; wire [63:0] disp_fpu0_Vk; wire [5:0] disp_fpu0_Qk;
    wire [4:0] disp_fpu1_op; wire [5:0] disp_fpu1_prd; wire [3:0] disp_fpu1_rt; wire [63:0] disp_fpu1_Vj; wire [5:0] disp_fpu1_Qj; wire [63:0] disp_fpu1_Vk; wire [5:0] disp_fpu1_Qk;
    wire [4:0] disp_md_op; wire [5:0] disp_md_prd; wire [3:0] disp_md_rt; wire [63:0] disp_md_Vj; wire [5:0] disp_md_Qj; wire [63:0] disp_md_Vk; wire [5:0] disp_md_Qk;
    wire [4:0] disp_mem_op; wire [5:0] disp_mem_prd; wire [3:0] disp_mem_rt; wire [11:0] disp_mem_imm; wire [63:0] disp_mem_Vj; wire [5:0] disp_mem_Qj; wire [63:0] disp_mem_Vk; wire [5:0] disp_mem_Qk;

    wire [4:0] f_op0, f_op1, f_rd0, f_rd1, f_rs0, f_rs1, f_rt0, f_rt1; wire f_br0, f_br1;
    wire commit_accept0, commit_accept1;
    wire is_any_br_iss;
    wire [31:0] fi0, fi1;
    wire [63:0] al_in_b;

    // ── WIRE ASSIGNMENTS ─────────────────────────────────────────────────────
    assign fi0 = {mu.bytes[pc+3], mu.bytes[pc+2], mu.bytes[pc+1], mu.bytes[pc]};
    assign fi1 = {mu.bytes[pc+7], mu.bytes[pc+6], mu.bytes[pc+5], mu.bytes[pc+4]};
    
    assign f_idx0 = pc[7:2]; assign f_tag0 = pc[63:12];
    assign btb_hit0 = btb_v[f_idx0] && btb_tag[f_idx0] == f_tag0;
    assign dec_pf = (writes_register(f_op0) && writes_register(f_op1) && (f_rd0 != f_rd1) && !same_packet_raw(f_op0, f_rd0, f_op1, f_rs1, f_rt1, f_rd1));
    assign dec_pair = (writes_register(opcode) && writes_register(opcode1) && (rd != rd1) && !same_packet_raw(opcode, rd, opcode1, rs1, rt1, rd1));

    assign is_f0 = (opcode >= 5'h14 && opcode <= 5'h17); assign is_f1 = (opcode1 >= 5'h14 && opcode1 <= 5'h17);
    assign is_m0 = (opcode == 5'h10 || opcode == 5'h13); assign is_m1 = (opcode1 == 5'h10 || opcode1 == 5'h13);
    assign is_md0= (opcode == 5'h1C || opcode == 5'h1D); assign is_md1= (opcode1 == 5'h1C || opcode1 == 5'h1D);
    assign is_i0 = (writes_register(opcode) && !is_f0 && !is_m0 && !is_md0) || is_br;
    assign is_i1 = (writes_register(opcode1) && !is_f1 && !is_m1 && !is_md1) || is_br1;

    assign disp_en0 = if_id_valid && !rob_full && (!is_i0 || !rs_int_full) && (!is_f0 || !rs_fpu0_full) && (!is_md0 || !rs_md_full) && (!is_m0 || !rs_mem_full);
    assign disp_en1 = if_id_valid1 && dec_pair && disp_en0 && (!is_i1 || !rs_int_full) && (!is_f1 || !rs_fpu1_full && (!is_f0 || !rs_fpu1_full)) && (!is_md1 || !rs_md_full) && (!is_m1 || !rs_mem_full);

    assign disp_en_int = (disp_en0 && is_i0) || (disp_en1 && is_i1);
    assign disp_int_op = (disp_en0 && is_i0)?opcode:opcode1; assign disp_int_prd=(disp_en0 && is_i0)?alloc_phys0:alloc_phys1; assign disp_int_rt=(disp_en0&&is_i0)?rob_tag0:rob_tag1; assign disp_int_Vj=(disp_en0&&is_i0)?rs_val:rs1_val; assign disp_int_Qj=(disp_en0&&is_i0)?(phys_busy[rat[rs]]?rat[rs]:0):(phys_busy[rat[rs1]]?rat[rs1]:0); assign disp_int_Vk=(disp_en0&&is_i0)?rt_val:rt1_val; assign disp_int_Qk=(disp_en0&&is_i0)?(phys_busy[rat[rt]]?rat[rt]:0):(phys_busy[rat[rt1]]?rat[rt1]:0); assign disp_int_Vrd=(disp_en0&&is_i0)?rd_val:rd1_val; assign disp_int_Qrd=(disp_en0&&is_i0)?(phys_busy[rat[rd]]?rat[rd]:0):(phys_busy[rat[rd1]]?rat[rd1]:0); assign disp_int_imm=(disp_en0&&is_i0)?imm:imm1; assign disp_int_uimm=(disp_en0&&is_i0)?use_imm:use_imm1; assign disp_int_pc=(disp_en0&&is_i0)?if_id_pc:if_id_pc1;

    assign disp_en_fpu0 = (disp_en0 && is_f0) || (disp_en1 && is_f1 && !is_f0); assign disp_fpu0_op=(disp_en0&&is_f0)?opcode:opcode1; assign disp_fpu0_prd=(disp_en0&&is_f0)?alloc_phys0:alloc_phys1; assign disp_fpu0_rt=(disp_en0&&is_f0)?rob_tag0:rob_tag1; assign disp_fpu0_Vj=(disp_en0&&is_f0)?rs_val:rs1_val; assign disp_fpu0_Qj=(disp_en0&&is_f0)?(phys_busy[rat[rs]]?rat[rs]:0):(phys_busy[rat[rs1]]?rat[rs1]:0); assign disp_fpu0_Vk=(disp_en0&&is_f0)?rt_val:rt1_val; assign disp_fpu0_Qk=(disp_en0&&is_f0)?(phys_busy[rat[rt]]?rat[rt]:0):(phys_busy[rat[rt1]]?rat[rt1]:0);
    assign disp_en_fpu1 = (disp_en1 && is_f1 && is_f0); assign disp_fpu1_op=opcode1; assign disp_fpu1_prd=alloc_phys1; assign disp_fpu1_rt=rob_tag1; assign disp_fpu1_Vj=rs1_val; assign disp_fpu1_Qj=phys_busy[rat[rs1]]?rat[rs1]:0; assign disp_fpu1_Vk=rt1_val; assign disp_fpu1_Qk=phys_busy[rat[rt1]]?rat[rt1]:0;
    assign disp_en_md = (disp_en0 && is_md0) || (disp_en1 && is_md1); assign disp_md_op=(disp_en0&&is_md0)?opcode:opcode1; assign disp_md_prd=(disp_en0&&is_md0)?alloc_phys0:alloc_phys1; assign disp_md_rt=(disp_en0&&is_md0)?rob_tag0:rob_tag1; assign disp_md_Vj=(disp_en0&&is_md0)?rs_val:rs1_val; assign disp_md_Qj=(disp_en0&&is_md0)?(phys_busy[rat[rs]]?rat[rs]:0):(phys_busy[rat[rs1]]?rat[rs1]:0); assign disp_md_Vk=(disp_en0&&is_md0)?rt_val:rt1_val; assign disp_md_Qk=(disp_en0&&is_md0)?(phys_busy[rat[rt]]?rat[rt]:0):(phys_busy[rat[rt1]]?rat[rt1]:0);
    assign disp_en_mem = (disp_en0 && is_m0) || (disp_en1 && is_m1); assign disp_mem_op=(disp_en0&&is_m0)?opcode:opcode1; assign disp_mem_prd=(disp_en0&&is_m0)?alloc_phys0:alloc_phys1; assign disp_mem_rt=(disp_en0&&is_m0)?rob_tag0:rob_tag1; assign disp_mem_imm=(disp_en0&&is_m0)?imm:imm1; assign disp_mem_Vj=(disp_en0&&is_m0)?rs_val:rs1_val; assign disp_mem_Qj=(disp_en0&&is_m0)?(phys_busy[rat[rs]]?rat[rs]:0):(phys_busy[rat[rs1]]?rat[rs1]:0); assign disp_mem_Vk=(disp_en0&&is_m0)?rd_val:rd1_val; assign disp_mem_Qk=(disp_en0&&is_m0)?(phys_busy[rat[rd]]?rat[rd]:0):(phys_busy[rat[rd1]]?rat[rd1]:0);

    assign commit_accept0 = rob_cv0 && !rob_flush; 
    assign commit_accept1 = rob_cv1 && !rob_flush;
    assign hlt = (halt_pending && rob_n_entries == 0);
    assign is_any_br_iss = (alu_op_issued==OP_BR||alu_op_issued==OP_BRR_R||alu_op_issued==OP_BRR_L||alu_op_issued==OP_BRNZ||alu_op_issued==OP_CALL||alu_op_issued==OP_BRGT);
    assign al_in_b = alu_uimm ? extend_imm(alu_op_issued, alu_imm) : alu_Vk;

    // ── INSTANTIATIONS ───────────────────────────────────────────────────────
    instruction_decoder f_d0 (.instruction(fi0), .opcode(f_op0), .rd(f_rd0), .rs(f_rs0), .rt(f_rt0), .is_branch(f_br0));
    instruction_decoder f_d1 (.instruction(fi1), .opcode(f_op1), .rd(f_rd1), .rs(f_rs1), .rt(f_rt1), .is_branch(f_br1));
    instruction_decoder d0 (.instruction(if_id_instr), .opcode(opcode), .rd(rd), .rs(rs), .rt(rt), .imm(imm), .use_immediate(use_imm), .is_branch(is_br));
    instruction_decoder d1 (.instruction(if_id_instr1), .opcode(opcode1), .rd(rd1), .rs(rs1), .rt(rt1), .imm(imm1), .use_immediate(use_imm1), .is_branch(is_br1));

    register_file rf (
        .clk(clk), .reset(reset),
        .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data),
        .commit_en0(commit_accept0), .commit_ard0(rob_card0), .commit_data0(rob_cres0),
        .commit_en1(commit_accept1), .commit_ard1(rob_card1), .commit_data1(rob_cres1),
        .rs0(rat[rs]),  .rt0(rat[rt]),  .rd0(rat[rd]),
        .rs1(rat[rs1]), .rt1(rat[rt1]), .rd1(rat[rd1]),
        .rs0_val(rs_val), .rt0_val(rt_val), .rd0_val(rd_val),
        .rs1_val(rs1_val), .rt1_val(rt1_val), .rd1_val(rd1_val), .r31_val(r31_val)
    );

    ROB rob_u (
        .clk(clk), .reset(reset),
        .disp_en0(disp_en0), .disp_opcode0(opcode), .disp_arch_rd0(rd), .disp_phys_rd0(alloc_phys0), .disp_pc0(if_id_pc), .disp_is_branch0(is_br), .disp_is_store0(opcode == OP_MOV_SM), .disp_tag0(rob_tag0),
        .disp_en1(disp_en1), .disp_opcode1(opcode1), .disp_arch_rd1(rd1), .disp_phys_rd1(alloc_phys1), .disp_pc1(if_id_pc1), .disp_is_branch1(is_br1), .disp_is_store1(opcode1 == OP_MOV_SM), .disp_tag1(rob_tag1),
        .disp_full(rob_full), .cdb_valid(cdb_valid), .cdb_rob_tag(cdb_rob_tag), .cdb_data(cdb_data),
        .bres_valid(alu_done && is_any_br_iss), .bres_rob_tag(alu_rt_out), .bres_mispred(br_mispred), .bres_tgt(br_corr_tgt),
        .su_valid(load_done && opcode_mem_issued == OP_MOV_SM), .su_rob_tag(load_rt), .su_addr(load_addr), .su_data(load_Vk),
        .cv0(rob_cv0), .cop0(rob_cop0), .card0(rob_card0), .cprd0(rob_cprd0), .cres0(rob_cres0), .cbr0(rob_cbr0), .cstore0(rob_cstore0), .csa0(rob_csa0), .csd0(rob_csd0), .cmp0(rob_cmp0), .ctgt0(rob_ctgt0), .ca0(commit_accept0),
        .cv1(rob_cv1), .cop1(rob_cop1), .card1(rob_card1), .cprd1(rob_cprd1), .cres1(rob_cres1), .cbr1(rob_cbr1), .cstore1(rob_cstore1), .csa1(rob_csa1), .csd1(rob_csd1), .cmp1(rob_cmp1), .ctgt1(rob_ctgt1), .ca1(commit_accept1),
        .n_entries(rob_n_entries), .rob_flush(rob_flush)
    );

    RS rs_int_u (
        .clk(clk), .reset(reset), .flush(rob_flush),
        .disp_en(disp_en_int), .disp_opcode(disp_int_op), .disp_phys_rd(disp_int_prd), .disp_rob_tag(disp_int_rt), .disp_Vj(disp_int_Vj), .disp_Qj(disp_int_Qj), .disp_Vk(disp_int_Vk), .disp_Qk(disp_int_Qk), .disp_imm(disp_int_imm), .disp_use_imm(disp_int_uimm), .disp_Vrd(disp_int_Vrd), .disp_Qrd(disp_int_Qrd), .disp_pc(disp_int_pc), .disp_full(rs_int_full),
        .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data),
        .issue_valid(alu_issue_valid), .issue_opcode(alu_op_issued), .issue_phys_rd(alu_prd_in), .issue_rob_tag(alu_rt_in), .issue_Vj(alu_Vj), .issue_Vk(alu_Vk), .issue_Qrd_out(alu_Qrd_tag), .issue_Vrd(alu_Vrd), .issue_imm(alu_imm), .issue_use_imm(alu_uimm), .issue_pc(alu_pc_iss), .issue_accept(alu_ready)
    );
    RS rs_fpu0_u (
        .clk(clk), .reset(reset), .flush(rob_flush), .disp_en(disp_en_fpu0), .disp_opcode(disp_fpu0_op), .disp_phys_rd(disp_fpu0_prd), .disp_rob_tag(disp_fpu0_rt), .disp_Vj(disp_fpu0_Vj), .disp_Qj(disp_fpu0_Qj), .disp_Vk(disp_fpu0_Vk), .disp_Qk(disp_fpu0_Qk), .disp_imm(12'd0), .disp_use_imm(1'b0), .disp_Vrd(64'd0), .disp_Qrd(6'd0), .disp_pc(64'd0), .disp_full(rs_fpu0_full), .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data), .issue_valid(fpu0_issue_valid), .issue_opcode(fpu0_op_issued), .issue_phys_rd(fpu0_prd_in), .issue_rob_tag(fpu0_rt_in), .issue_Vj(fpu0_Vj), .issue_Vk(fpu0_Vk), .issue_accept(fpu0_ready)
    );
    RS rs_fpu1_u (
        .clk(clk), .reset(reset), .flush(rob_flush), .disp_en(disp_en_fpu1), .disp_opcode(disp_fpu1_op), .disp_phys_rd(disp_fpu1_prd), .disp_rob_tag(disp_fpu1_rt), .disp_Vj(disp_fpu1_Vj), .disp_Qj(disp_fpu1_Qj), .disp_Vk(disp_fpu1_Vk), .disp_Qk(disp_fpu1_Qk), .disp_imm(12'd0), .disp_use_imm(1'b0), .disp_Vrd(64'd0), .disp_Qrd(6'd0), .disp_pc(64'd0), .disp_full(rs_fpu1_full), .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data), .issue_valid(fpu1_issue_valid), .issue_opcode(fpu1_op_issued), .issue_phys_rd(fpu1_prd_in), .issue_rob_tag(fpu1_rt_in), .issue_Vj(fpu1_Vj), .issue_Vk(fpu1_Vk), .issue_accept(fpu1_ready)
    );
    RS rs_md_u (
        .clk(clk), .reset(reset), .flush(rob_flush), .disp_en(disp_en_md), .disp_opcode(disp_md_op), .disp_phys_rd(disp_md_prd), .disp_rob_tag(disp_md_rt), .disp_Vj(disp_md_Vj), .disp_Qj(disp_md_Qj), .disp_Vk(disp_md_Vk), .disp_Qk(disp_md_Qk), .disp_imm(12'd0), .disp_use_imm(1'b0), .disp_Vrd(64'd0), .disp_Qrd(6'd0), .disp_pc(64'd0), .disp_full(rs_md_full), .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data), .issue_valid(muldiv_issue_valid), .issue_opcode(muldiv_op_issued), .issue_phys_rd(muldiv_prd_in), .issue_rob_tag(muldiv_rt_in), .issue_Vj(muldiv_Vj), .issue_Vk(muldiv_Vk), .issue_accept(muldiv_ready)
    );
    RS_Mem rs_mem_u (
        .clk(clk), .reset(reset), .flush(rob_flush), .disp_en(disp_en_mem), .disp_opcode(disp_mem_op), .disp_phys_rd(disp_mem_prd), .disp_rob_tag(disp_mem_rt), .disp_Vj(disp_mem_Vj), .disp_Qj(disp_mem_Qj), .disp_Vk(disp_mem_Vk), .disp_Qk(disp_mem_Qk), .disp_imm(disp_mem_imm), .disp_full(rs_mem_full), .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data), .issue_valid(load_issue_valid), .issue_opcode(opcode_mem_issued), .issue_phys_rd(load_prd), .issue_rob_tag(load_rt), .issue_Vj(load_Vj), .issue_Vk(load_Vk), .issue_imm(load_imm), .issue_accept(load_ready)
    );

    ALU al_u (.clk(clk), .reset(reset), .start(alu_issue_valid), .a(alu_Vj), .b(al_in_b), .op(alu_op_issued), .phys_rd_in(alu_prd_in), .rob_tag_in(alu_rt_in), .pc_in(alu_pc_iss), .accept(cdb_accept_alu), .res(alu_res_dir), .phys_rd_out(alu_prd_out), .rob_tag_out(alu_rt_out), .op_out(alu_op_out), .pc_out(alu_pc_out), .done(alu_done), .ready(alu_ready));
    FPU f0_u (.clk(clk), .reset(reset), .start(fpu0_issue_valid), .a(fpu0_Vj), .b(fpu0_Vk), .op(fpu0_op_issued), .phys_rd_in(fpu0_prd_in), .rob_tag_in(fpu0_rt_in), .arch_rd_in(5'd0), .accept(cdb_accept_fpu0), .res(fpu0_res), .phys_rd_out(fpu0_prd_out), .rob_tag_out(fpu0_rt_out), .done(fpu0_done), .ready(fpu0_ready));
    FPU f1_u (.clk(clk), .reset(reset), .start(fpu1_issue_valid), .a(fpu1_Vj), .b(fpu1_Vk), .op(fpu1_op_issued), .phys_rd_in(fpu1_prd_in), .rob_tag_in(fpu1_rt_in), .arch_rd_in(5'd0), .accept(cdb_accept_fpu1), .res(fpu1_res), .phys_rd_out(fpu1_prd_out), .rob_tag_out(fpu1_rt_out), .done(fpu1_done), .ready(fpu1_ready));
    ALU md_u (.clk(clk), .reset(reset), .start(muldiv_issue_valid), .a(muldiv_Vj), .b(muldiv_Vk), .op(muldiv_op_issued), .phys_rd_in(muldiv_prd_in), .rob_tag_in(muldiv_rt_in), .pc_in(64'd0), .accept(cdb_accept_md), .res(muldiv_res_dir), .phys_rd_out(muldiv_prd_out), .rob_tag_out(muldiv_rt_out), .op_out(muldiv_op_out), .pc_out(muldiv_pc_out), .done(muldiv_done), .ready(muldiv_ready));
    memory mu (.clk(clk), .addr((opcode_mem_issued==OP_MOV_ML)?load_addr:64'd0), .write_data(64'd0), .mem_write(1'b0), .mem_read((opcode_mem_issued==OP_MOV_ML)&&load_issue_valid), .read_data(load_res));

    // ── PROCEDURAL LOGIC ───────────────────────────────────────────────────────
    always @(*) begin 
        alloc0_ok=0; alloc1_ok=0; alloc_phys0=0; alloc_phys1=0; tf_s = temp_free; 
        for (alloc_i=0; alloc_i<32; alloc_i=alloc_i+1) begin 
            if (!alloc0_ok && tf_s[alloc_i]) begin alloc0_ok=1; alloc_phys0=alloc_i+32; tf_s[alloc_i]=0; end 
            else if (!alloc1_ok && tf_s[alloc_i]) begin alloc1_ok=1; alloc_phys1=alloc_i+32; tf_s[alloc_i]=0; end 
        end 
    end

    // CDB Arbiter: Fully synchronous with PRIORITY and HANDSHAKING
    always @(posedge clk) begin
        if (reset || rob_flush) begin
            cdb_valid <= 0; cdb_tag <= 0; cdb_data <= 0; cdb_rob_tag <= 0;
            cdb_accept_fpu0 <= 0; cdb_accept_fpu1 <= 0; cdb_accept_alu <= 0; cdb_accept_md <= 0; cdb_accept_load <= 0;
        end else begin
            cdb_valid <= 0;
            cdb_accept_fpu0 <= 0; cdb_accept_fpu1 <= 0; cdb_accept_alu <= 0; cdb_accept_md <= 0; cdb_accept_load <= 0;
            
            // PRIORITY: Latent units first to prevent starvation by ALU/NOPs
            if (muldiv_done) begin 
                cdb_valid <= 1; cdb_tag <= muldiv_prd_out; cdb_data <= muldiv_res_dir; cdb_rob_tag <= muldiv_rt_out; cdb_accept_md <= 1;
            end else if (fpu0_done) begin 
                cdb_valid <= 1; cdb_tag <= fpu0_prd_out; cdb_data <= fpu0_res; cdb_rob_tag <= fpu0_rt_out; cdb_accept_fpu0 <= 1;
            end else if (fpu1_done) begin 
                cdb_valid <= 1; cdb_tag <= fpu1_prd_out; cdb_data <= fpu1_res; cdb_rob_tag <= fpu1_rt_out; cdb_accept_fpu1 <= 1;
            end else if (load_done && opcode_mem_issued==OP_MOV_ML) begin 
                cdb_valid <= 1; cdb_tag <= load_prd; cdb_data <= load_res; cdb_rob_tag <= load_rt; cdb_accept_load <= 1;
            end else if (alu_done) begin 
                cdb_valid <= 1; cdb_tag <= alu_prd_out; cdb_data <= (alu_op_out == OP_CALL)?(alu_pc_out+4):alu_res_dir; cdb_rob_tag <= alu_rt_out; cdb_accept_alu <= 1;
            end
        end
    end
    assign load_ready=1;

    always @(*) begin
        br_mispred=0; br_corr_tgt=0;
        if (alu_done && (alu_op_out==OP_BR || alu_op_out==OP_BRR_R || alu_op_out==OP_CALL || alu_op_out==OP_BRR_L || alu_op_out==OP_BRNZ || alu_op_out==OP_BRGT)) begin
            case (alu_op_out)
                OP_BR, OP_BRR_R, OP_CALL: begin br_mispred=1; br_corr_tgt=alu_res_dir; end 
                OP_BRR_L: begin br_mispred=1; br_corr_tgt=alu_res_dir; end
                OP_BRNZ: begin br_mispred=(alu_Vj != 0); br_corr_tgt=alu_Vrd; end
                OP_BRGT: begin br_mispred=($signed(alu_Vj) > $signed(alu_Vk)); br_corr_tgt=alu_Vrd; end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset || rob_flush) begin
            pc <= reset ? 64'd0 : rob_ctgt0; if_id_valid <= 0; if_id_valid1 <= 0; halt_pending <= 0; temp_free <= 32'hFFFFFFFF; phys_busy <= 64'b0; debug_cycles <= 0;
            for (i=0; i<32; i=i+1) begin rat[i]<=i[5:0]; amt[i]<=i[5:0]; end
        end else begin
            debug_cycles <= debug_cycles + 1;
            if (!rob_full) begin
                pc <= (f_br0 && btb_hit0 && bht[f_idx0] >= 2'b10) ? btb_tgt[f_idx0] : (dec_pf ? pc+8 : pc+4);
                if_id_valid <= 1; if_id_pc <= pc; if_id_instr <= fi0; if_id_valid1 <= dec_pf; if_id_pc1 <= pc+4; if_id_instr1 <= fi1;
            end
            if (disp_en0) begin 
                if (writes_register(opcode)) begin rat[rd]<=alloc_phys0; phys_busy[alloc_phys0]<=1; temp_free[alloc_phys0-32]<=0; end 
                $display("Cycle %d: Dispatch instr=%h rd=%d (phys=%d) Tag=%d", debug_cycles, if_id_instr, rd, alloc_phys0, rob_tag0);
            end
            if (disp_en1) begin
                if (writes_register(opcode1)) begin rat[rd1]<=alloc_phys1; phys_busy[alloc_phys1]<=1; temp_free[alloc_phys1-32]<=0; end
                $display("Cycle %d: Dispatch1 instr=%h rd1=%d (phys1=%d) Tag1=%d", debug_cycles, if_id_instr1, rd1, alloc_phys1, rob_tag1);
            end
            if (cdb_valid) $display("Cycle %d: CDB Generic Broadcast Tag=%d Data=%h RobTag=%d", debug_cycles, cdb_tag, cdb_data, cdb_rob_tag);
            if (commit_accept1) begin 
                amt[rob_card0]<=rob_cprd0; amt[rob_card1]<=rob_cprd1; phys_busy[rob_cprd0]<=0; phys_busy[rob_cprd1]<=0; 
                $display("Cycle %d: Commit Dual %d, %d", debug_cycles, rob_card0, rob_card1);
            end else if (commit_accept0) begin 
                amt[rob_card0]<=rob_cprd0; phys_busy[rob_cprd0]<=0; 
                $display("Cycle %d: Commit Single %d", debug_cycles, rob_card0);
            end
            if (rob_cv0 && rob_cop0 == OP_PRIV && rob_card0 == 0) halt_pending <= 1;
            if (alu_issue_valid) $display("Cycle %d: ALU Issue Op=%h tag=%d RobTag=%d", debug_cycles, alu_op_issued, alu_prd_in, alu_rt_in);
            if (fpu0_issue_valid) $display("Cycle %d: FPU Issue Op=%h tag=%d RobTag=%d", debug_cycles, fpu0_op_issued, fpu0_prd_in, fpu0_rt_in);
            if (muldiv_issue_valid) $display("Cycle %d: MulDiv Issue Op=%h tag=%d RobTag=%d", debug_cycles, muldiv_op_issued, muldiv_prd_in, muldiv_rt_in);
        end
    end
endmodule
