`include "hdl/instruction_decoder.sv"
`include "hdl/register_file.sv"
`include "hdl/ALU.sv"
`include "hdl/FPU.sv"
`include "hdl/memory.sv"

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
    localparam OP_AND    = 5'h00;
    localparam OP_OR     = 5'h01;
    localparam OP_XOR    = 5'h02;
    localparam OP_NOT    = 5'h03;
    localparam OP_SHFTR  = 5'h04;
    localparam OP_SHFTRI = 5'h05;
    localparam OP_SHFTL  = 5'h06;
    localparam OP_SHFTLI = 5'h07;
    localparam OP_BR     = 5'h08;
    localparam OP_BRR_R  = 5'h09;
    localparam OP_BRR_L  = 5'h0A;
    localparam OP_BRNZ   = 5'h0B;
    localparam OP_CALL   = 5'h0C;
    localparam OP_RET    = 5'h0D;
    localparam OP_BRGT   = 5'h0E;
    localparam OP_PRIV   = 5'h0F;
    localparam OP_MOV_ML = 5'h10;
    localparam OP_MOV_RR = 5'h11;
    localparam OP_MOV_L  = 5'h12;
    localparam OP_MOV_SM = 5'h13;
    localparam OP_ADDF   = 5'h14;
    localparam OP_SUBF   = 5'h15;
    localparam OP_MULF   = 5'h16;
    localparam OP_DIVF   = 5'h17;
    localparam OP_ADD    = 5'h18;
    localparam OP_ADDI   = 5'h19;
    localparam OP_SUB    = 5'h1A;
    localparam OP_SUBI   = 5'h1B;
    localparam OP_MUL    = 5'h1C;
    localparam OP_DIV    = 5'h1D;

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
                default:
                    writes_register = 1'b0;
            endcase
        end
    endfunction

    function uses_rs;
        input [4:0] op;
        begin
            case (op)
                OP_AND, OP_OR, OP_XOR, OP_NOT,
                OP_SHFTR, OP_SHFTL,
                OP_BRNZ, OP_BRGT,
                OP_MOV_ML, OP_MOV_RR, OP_MOV_SM,
                OP_ADDF, OP_SUBF, OP_MULF, OP_DIVF,
                OP_ADD, OP_SUB, OP_MUL, OP_DIV:
                    uses_rs = 1'b1;
                default:
                    uses_rs = 1'b0;
            endcase
        end
    endfunction

    function uses_rt;
        input [4:0] op;
        begin
            case (op)
                OP_AND, OP_OR, OP_XOR,
                OP_SHFTR, OP_SHFTL,
                OP_BRGT,
                OP_ADDF, OP_SUBF, OP_MULF, OP_DIVF,
                OP_ADD, OP_SUB, OP_MUL, OP_DIV:
                    uses_rt = 1'b1;
                default:
                    uses_rt = 1'b0;
            endcase
        end
    endfunction

    function uses_rd_source;
        input [4:0] op;
        begin
            case (op)
                OP_BR, OP_BRR_R, OP_BRNZ, OP_CALL, OP_BRGT,
                OP_SHFTRI, OP_SHFTLI, OP_ADDI, OP_SUBI,
                OP_MOV_L, OP_MOV_SM:
                    uses_rd_source = 1'b1;
                default:
                    uses_rd_source = 1'b0;
            endcase
        end
    endfunction

    function uses_rd_as_alu_a;
        input [4:0] op;
        begin
            case (op)
                OP_MOV_SM, OP_ADDI, OP_SUBI, OP_SHFTRI, OP_SHFTLI, OP_MOV_L:
                    uses_rd_as_alu_a = 1'b1;
                default:
                    uses_rd_as_alu_a = 1'b0;
            endcase
        end
    endfunction

    function [63:0] extend_imm;
        input [4:0] op;
        input [11:0] value;
        begin
            if (op == OP_ADDI || op == OP_SUBI) begin
                extend_imm = {52'b0, value};
            end else begin
                extend_imm = {{52{value[11]}}, value};
            end
        end
    endfunction

    function slot1_eligible;
        input [4:0] op;
        input is_branch_flag;
        begin
            slot1_eligible = writes_register(op) &&
                             !is_branch_flag &&
                             (op != OP_MOV_ML) &&
                             (op != OP_PRIV);
        end
    endfunction

    function same_packet_raw;
        input [4:0] op0;
        input [4:0] rd0;
        input [4:0] op1;
        input [4:0] rs1;
        input [4:0] rt1;
        input [4:0] rd1_src;
        begin
            same_packet_raw = writes_register(op0) &&
                              ((uses_rs(op1) && (rs1 == rd0)) ||
                               (uses_rt(op1) && (rt1 == rd0)) ||
                               (uses_rd_source(op1) && (rd1_src == rd0)));
        end
    endfunction

    reg [63:0] pc;
    integer i;
    integer alloc_i;
    reg halt_pending;

    reg [5:0] rat [0:31];
    reg [5:0] amt [0:31];
    reg [31:0] temp_free;
    reg [63:0] phys_busy;

    reg if_id_valid;
    reg [63:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg if_id_valid1;
    reg [63:0] if_id_pc1;
    reg [31:0] if_id_instr1;

    reg id_ex1_valid;
    reg [63:0] ex1_pc;
    reg [4:0] ex1_opcode;
    reg [4:0] ex1_rd;
    reg [4:0] ex1_rs;
    reg [4:0] ex1_rt;
    reg [11:0] ex1_imm;
    reg ex1_use_immediate;
    reg ex1_use_fpu_instruction;
    reg ex1_is_branch;
    reg ex1_predicted_taken;
    reg [63:0] ex1_predicted_target;
    reg [5:0] ex1_phys_rd;
    reg id_ex1_valid1;
    reg [63:0] ex1_pc1;
    reg [4:0] ex1_opcode1;
    reg [4:0] ex1_rd1;
    reg [4:0] ex1_rs1;
    reg [4:0] ex1_rt1;
    reg [11:0] ex1_imm1;
    reg ex1_use_immediate1;
    reg ex1_use_fpu_instruction1;
    reg [5:0] ex1_phys_rd1;

    reg ex1_ex2_valid;
    reg [63:0] ex2_pc;
    reg [4:0] ex2_opcode;
    reg [4:0] ex2_rd;
    reg [63:0] ex2_A;
    reg [63:0] ex2_B;
    reg [63:0] ex2_RD_LATCH;
    reg [11:0] ex2_imm;
    reg ex2_use_immediate;
    reg ex2_use_fpu_instruction;
    reg ex2_is_branch;
    reg ex2_predicted_taken;
    reg [63:0] ex2_predicted_target;
    reg ex2_long_op_started;
    reg ex2_long_op_complete;
    reg [5:0] ex2_phys_rd;
    reg ex1_ex2_valid1;
    reg [63:0] ex2_pc1;
    reg [4:0] ex2_opcode1;
    reg [4:0] ex2_rd1;
    reg [63:0] ex2_A1;
    reg [63:0] ex2_B1;
    reg [63:0] ex2_RD_LATCH1;
    reg [11:0] ex2_imm1;
    reg ex2_use_immediate1;
    reg ex2_use_fpu_instruction1;
    reg ex2_long_op_started1;
    reg ex2_long_op_complete1;
    reg [5:0] ex2_phys_rd1;

    reg ex2_mem_valid;
    reg [63:0] mem_pc;
    reg [4:0] mem_opcode;
    reg [4:0] mem_rd;
    reg [5:0] mem_phys_rd;
    reg [63:0] mem_store_data;
    reg ex2_mem_valid1;
    reg [63:0] mem_pc1;
    reg [4:0] mem_opcode1;
    reg [4:0] mem_rd1;
    reg [5:0] mem_phys_rd1;

    reg mem_wb_valid;
    reg [4:0] wb_opcode;
    reg [4:0] wb_rd;
    reg [5:0] wb_phys_rd;
    reg [63:0] wb_alu_out;
    reg [63:0] wb_fpu_out;
    reg mem_wb_valid1;
    reg [4:0] wb_opcode1;
    reg [4:0] wb_rd1;
    reg [5:0] wb_phys_rd1;
    reg [63:0] wb_alu_out1;
    reg [63:0] wb_fpu_out1;

    reg [63:0] A;
    reg [63:0] B;
    reg [63:0] RD_LATCH;
    reg [63:0] A1;
    reg [63:0] B1;
    reg [63:0] RD_LATCH1;
    reg [63:0] ALUOut;
    reg [63:0] FPUOut;
    reg [63:0] ALUOut1;
    reg [63:0] FPUOut1;
    reg [63:0] MDR;

    wire [31:0] fetch_instr0 = {memory.bytes[pc+3], memory.bytes[pc+2], memory.bytes[pc+1], memory.bytes[pc]};
    wire [31:0] fetch_instr1 = {memory.bytes[pc+7], memory.bytes[pc+6], memory.bytes[pc+5], memory.bytes[pc+4]};

    wire [4:0] fetch_opcode0, fetch_rd0, fetch_rs0, fetch_rt0;
    wire [11:0] fetch_imm0;
    wire fetch_use_immediate0, fetch_use_fpu_instruction0, fetch_is_branch0;
    wire [4:0] fetch_opcode1, fetch_rd1, fetch_rs1, fetch_rt1;
    wire [11:0] fetch_imm1;
    wire fetch_use_immediate1, fetch_use_fpu_instruction1, fetch_is_branch1;

    instruction_decoder fetch_decoder0 (
        .instruction(fetch_instr0),
        .opcode(fetch_opcode0),
        .rd(fetch_rd0),
        .rs(fetch_rs0),
        .rt(fetch_rt0),
        .imm(fetch_imm0),
        .use_immediate(fetch_use_immediate0),
        .use_fpu_instruction(fetch_use_fpu_instruction0),
        .is_branch(fetch_is_branch0)
    );

    instruction_decoder fetch_decoder1 (
        .instruction(fetch_instr1),
        .opcode(fetch_opcode1),
        .rd(fetch_rd1),
        .rs(fetch_rs1),
        .rt(fetch_rt1),
        .imm(fetch_imm1),
        .use_immediate(fetch_use_immediate1),
        .use_fpu_instruction(fetch_use_fpu_instruction1),
        .is_branch(fetch_is_branch1)
    );

    wire [4:0] opcode, rd, rs, rt;
    wire [11:0] imm;
    wire use_immediate;
    wire use_fpu_instruction;
    wire is_branch;

    wire [4:0] opcode1, rd1, rs1, rt1;
    wire [11:0] imm1;
    wire use_immediate1;
    wire use_fpu_instruction1;
    wire is_branch1;

    instruction_decoder decoder0 (
        .instruction(if_id_instr),
        .opcode(opcode),
        .rd(rd),
        .rs(rs),
        .rt(rt),
        .imm(imm),
        .use_immediate(use_immediate),
        .use_fpu_instruction(use_fpu_instruction),
        .is_branch(is_branch)
    );

    instruction_decoder decoder1 (
        .instruction(if_id_instr1),
        .opcode(opcode1),
        .rd(rd1),
        .rs(rs1),
        .rt(rt1),
        .imm(imm1),
        .use_immediate(use_immediate1),
        .use_fpu_instruction(use_fpu_instruction1),
        .is_branch(is_branch1)
    );

    wire decode_pairable_packet =
        slot1_eligible(opcode, is_branch) &&
        slot1_eligible(opcode1, is_branch1) &&
        !same_packet_raw(opcode, rd, opcode1, rs1, rt1, rd1) &&
        !(writes_register(opcode) && writes_register(opcode1) && (rd == rd1));

    wire [5:0] rd_phys = rat[rd];
    wire [5:0] rs_phys = rat[rs];
    wire [5:0] rt_phys = rat[rt];
    wire [5:0] rd1_phys = rat[rd1];
    wire [5:0] rs1_phys = rat[rs1];
    wire [5:0] rt1_phys = rat[rt1];

    reg alloc0_ok;
    reg alloc1_ok;
    reg [5:0] alloc_phys0;
    reg [5:0] alloc_phys1;
    reg [31:0] temp_free_scan;

    always @(*) begin
        alloc0_ok = !if_id_valid || !writes_register(opcode);
        alloc1_ok = !if_id_valid1 || !decode_pairable_packet || !writes_register(opcode1);
        alloc_phys0 = 6'b0;
        alloc_phys1 = 6'b0;
        temp_free_scan = temp_free;

        if (if_id_valid && writes_register(opcode)) begin
            alloc0_ok = 1'b0;
            for (alloc_i = 0; alloc_i < 32; alloc_i = alloc_i + 1) begin
                if (!alloc0_ok && temp_free_scan[alloc_i]) begin
                    alloc0_ok = 1'b1;
                    alloc_phys0 = alloc_i + 6'd32;
                    temp_free_scan[alloc_i] = 1'b0;
                end
            end
        end

        if (if_id_valid1 && decode_pairable_packet && writes_register(opcode1)) begin
            alloc1_ok = 1'b0;
            for (alloc_i = 0; alloc_i < 32; alloc_i = alloc_i + 1) begin
                if (!alloc1_ok && temp_free_scan[alloc_i]) begin
                    alloc1_ok = 1'b1;
                    alloc_phys1 = alloc_i + 6'd32;
                    temp_free_scan[alloc_i] = 1'b0;
                end
            end
        end
    end

    wire rename_stall =
        (if_id_valid && writes_register(opcode) && !alloc0_ok) ||
        (if_id_valid1 && decode_pairable_packet && writes_register(opcode1) && !alloc1_ok);

    wire [63:0] rd_val, rs_val, rt_val;
    wire [63:0] rd1_val, rs1_val, rt1_val;
    wire [63:0] r31_val;

    wire [63:0] reg_write_data;
    wire [63:0] reg_write_data1;
    wire reg_write_en;
    wire reg_write_en1;
    wire [5:0] reg_write_rd;
    wire [5:0] reg_write_rd1;
    wire [63:0] commit_data0;
    wire [63:0] commit_data1;
    wire commit_en0;
    wire commit_en1;

    wire [63:0] alu_res, fpu_res, alu_res1, fpu_res1;
    wire alu_busy, alu_done, fpu_busy, fpu_done;
    wire alu_busy1, alu_done1, fpu_busy1, fpu_done1;

    wire [63:0] fpu_s1_res, fpu_s2_res, fpu_s3_res, fpu_s4_res;
    wire [5:0] fpu_s1_rd, fpu_s2_rd, fpu_s3_rd, fpu_s4_rd;
    wire fpu_s1_v, fpu_s2_v, fpu_s3_v, fpu_s4_v;
    wire [5:0] fpu_phys_rd_out;

    wire [63:0] fpu1_s1_res, fpu1_s2_res, fpu1_s3_res, fpu1_s4_res;
    wire [5:0] fpu1_s1_rd, fpu1_s2_rd, fpu1_s3_rd, fpu1_s4_rd;
    wire fpu1_s1_v, fpu1_s2_v, fpu1_s3_v, fpu1_s4_v;
    wire [5:0] fpu1_phys_rd_out;
    wire [4:0] fpu_arch_rd_out, fpu1_arch_rd_out;

    register_file reg_file (
        .clk(clk),
        .reset(reset),
        .phys_data0(reg_write_data),
        .phys_data1(reg_write_data1),
        .rd0(rd_phys),
        .rs0(rs_phys),
        .rt0(rt_phys),
        .rd1(rd1_phys),
        .rs1(rs1_phys),
        .rt1(rt1_phys),
        .phys_write_rd0(reg_write_rd),
        .phys_write_rd1(reg_write_rd1),
        .phys_write_enable0(reg_write_en),
        .phys_write_enable1(reg_write_en1),
        // FPU Asynchronous Write Ports
        .fpu_data0(fpu_res),
        .fpu_data1(fpu_res1),
        .fpu_write_rd0(fpu_phys_rd_out),
        .fpu_write_rd1(fpu1_phys_rd_out),
        .fpu_arch_rd0(fpu_arch_rd_out),
        .fpu_arch_rd1(fpu1_arch_rd_out),
        .fpu_write_enable0(fpu_done),
        .fpu_write_enable1(fpu_done1),
        .commit_data0(commit_data0),
        .commit_data1(commit_data1),
        .commit_arch_rd0(mem_rd),
        .commit_arch_rd1(mem_rd1),
        .commit_enable0(commit_en0),
        .commit_enable1(commit_en1),
        .commit_is_fpu0(wb_opcode >= 5'h14 && wb_opcode <= 5'h17),
        .commit_is_fpu1(wb_opcode1 >= 5'h14 && wb_opcode1 <= 5'h17),
        .rd0_val(rd_val),
        .rs0_val(rs_val),
        .rt0_val(rt_val),
        .rd1_val(rd1_val),
        .rs1_val(rs1_val),
        .rt1_val(rt1_val),
        .r31_val(r31_val)
    );

    wire [63:0] mem_read_data;

    reg [1:0]  bht [0:63];
    reg [63:0] btb_tgt [0:63];
    reg [51:0] btb_tag [0:63];
    reg [63:0] btb_valid;

    reg [63:0] sb_addr [0:3];
    reg [63:0] sb_data [0:3];
    reg [3:0] sb_valid;
    reg [1:0] sb_head;
    reg [1:0] sb_tail;
    reg [2:0] sb_count;

    wire [63:0] stack_addr = r31_val - 64'd8;

    wire [63:0] alu_input_a0 = uses_rd_as_alu_a(ex2_opcode) ? ex2_RD_LATCH : ex2_A;
    wire [63:0] alu_input_b0 = ex2_use_immediate ? extend_imm(ex2_opcode, ex2_imm) : ex2_B;
    wire [63:0] alu_input_a1 = uses_rd_as_alu_a(ex2_opcode1) ? ex2_RD_LATCH1 : ex2_A1;
    wire [63:0] alu_input_b1 = ex2_use_immediate1 ? extend_imm(ex2_opcode1, ex2_imm1) : ex2_B1;


    wire ex2_needs_alu_pipe = ex1_ex2_valid && !ex2_use_fpu_instruction && (ex2_opcode == OP_MUL || ex2_opcode == OP_DIV);
    wire ex2_needs_fpu_pipe = ex1_ex2_valid && ex2_use_fpu_instruction && writes_register(ex2_opcode);
    wire ex2_needs_alu_pipe1 = ex1_ex2_valid1 && !ex2_use_fpu_instruction1 && (ex2_opcode1 == OP_MUL || ex2_opcode1 == OP_DIV);
    wire ex2_needs_fpu_pipe1 = ex1_ex2_valid1 && ex2_use_fpu_instruction1 && writes_register(ex2_opcode1);
    wire alu_start = ex2_needs_alu_pipe && !ex2_long_op_started;
    wire fpu_start = ex2_needs_fpu_pipe && !ex2_long_op_started; // This will still rely on started/complete for the 1-cycle duration
    wire alu_start1 = ex2_needs_alu_pipe1 && !ex2_long_op_started1;
    wire fpu_start1 = ex2_needs_fpu_pipe1 && !ex2_long_op_started1;

    ALU alu_inst (
        .clk(clk),
        .reset(reset),
        .start(alu_start),
        .a(alu_input_a0),
        .b(alu_input_b0),
        .op(ex2_opcode),
        .res(alu_res),
        .busy(alu_busy),
        .done(alu_done)
    );

    FPU fpu (
        .clk(clk),
        .reset(reset),
        .start(fpu_start),
        .a(ex2_A),
        .b(alu_input_b0),
        .op(ex2_opcode),
        .phys_rd_in(ex2_phys_rd),
        .arch_rd_in(ex2_rd),
        .res(fpu_res),
        .busy(fpu_busy),
        .done(fpu_done),
        .phys_rd_out(fpu_phys_rd_out),
        .arch_rd_out(fpu_arch_rd_out),
        .s1_res_out(fpu_s1_res),
        .s2_res_out(fpu_s2_res),
        .s3_res_out(fpu_s3_res),
        .s4_res_out(fpu_s4_res),
        .s1_rd_out(fpu_s1_rd),
        .s2_rd_out(fpu_s2_rd),
        .s3_rd_out(fpu_s3_rd),
        .s4_rd_out(fpu_s4_rd),
        .s1_valid(fpu_s1_v),
        .s2_valid(fpu_s2_v),
        .s3_valid(fpu_s3_v),
        .s4_valid(fpu_s4_v)
    );

    ALU alu_inst1 (
        .clk(clk),
        .reset(reset),
        .start(alu_start1),
        .a(alu_input_a1),
        .b(alu_input_b1),
        .op(ex2_opcode1),
        .res(alu_res1),
        .busy(alu_busy1),
        .done(alu_done1)
    );

    FPU fpu_inst1 (
        .clk(clk),
        .reset(reset),
        .start(fpu_start1),
        .a(ex2_A1),
        .b(alu_input_b1),
        .op(ex2_opcode1),
        .phys_rd_in(ex2_phys_rd1),
        .arch_rd_in(ex2_rd1),
        .res(fpu_res1),
        .busy(fpu_busy1),
        .done(fpu_done1),
        .phys_rd_out(fpu1_phys_rd_out),
        .arch_rd_out(fpu1_arch_rd_out),
        .s1_res_out(fpu1_s1_res),
        .s2_res_out(fpu1_s2_res),
        .s3_res_out(fpu1_s3_res),
        .s4_res_out(fpu1_s4_res),
        .s1_rd_out(fpu1_s1_rd),
        .s2_rd_out(fpu1_s2_rd),
        .s3_rd_out(fpu1_s3_rd),
        .s4_rd_out(fpu1_s4_rd),
        .s1_valid(fpu1_s1_v),
        .s2_valid(fpu1_s2_v),
        .s3_valid(fpu1_s3_v),
        .s4_valid(fpu1_s4_v)
    );

    wire phys_addr_is_stack = (mem_opcode == OP_CALL || mem_opcode == OP_RET);
    wire [63:0] mem_addr = phys_addr_is_stack ? stack_addr : ALUOut;

    wire slf_hit0 = sb_valid[0] && (sb_addr[0] == mem_addr);
    wire slf_hit1 = sb_valid[1] && (sb_addr[1] == mem_addr);
    wire slf_hit2 = sb_valid[2] && (sb_addr[2] == mem_addr);
    wire slf_hit3 = sb_valid[3] && (sb_addr[3] == mem_addr);
    wire [1:0] rel_idx0 = 0 - sb_head;
    wire [1:0] rel_idx1 = 1 - sb_head;
    wire [1:0] rel_idx2 = 2 - sb_head;
    wire [1:0] rel_idx3 = 3 - sb_head;
    wire slf_hit = slf_hit0 | slf_hit1 | slf_hit2 | slf_hit3;
    wire [63:0] slf_data =
        (slf_hit3 && (rel_idx3 >= rel_idx2 || !slf_hit2) && (rel_idx3 >= rel_idx1 || !slf_hit1) && (rel_idx3 >= rel_idx0 || !slf_hit0)) ? sb_data[3] :
        (slf_hit2 && (rel_idx2 >= rel_idx1 || !slf_hit1) && (rel_idx2 >= rel_idx0 || !slf_hit0)) ? sb_data[2] :
        (slf_hit1 && (rel_idx1 >= rel_idx0 || !slf_hit0)) ? sb_data[1] :
        sb_data[0];

    wire [63:0] phys_mem_read_data = memory.read_data;
    wire [63:0] forwarded_mem_read_data = slf_hit ? slf_data : phys_mem_read_data;

    assign reg_write_data = (mem_opcode == OP_MOV_ML) ? forwarded_mem_read_data :
                            (mem_opcode >= OP_ADDF && mem_opcode <= OP_DIVF) ? FPUOut :
                            ALUOut;
    assign reg_write_data1 = (mem_opcode1 >= OP_ADDF && mem_opcode1 <= OP_DIVF) ? FPUOut1 : ALUOut1;
    assign commit_data0 = reg_write_data;
    assign commit_data1 = reg_write_data1;
    assign commit_en0 = reg_write_en;
    assign commit_en1 = reg_write_en1;

    reg take_branch;
    reg [63:0] branch_target;

    wire [5:0] pred_idx = pc[7:2];
    wire [51:0] curr_tag = pc[63:12];
    wire btb_hit = btb_valid[pred_idx] && (btb_tag[pred_idx] == curr_tag);
    wire predict_takenRaw = btb_hit && (bht[pred_idx] >= 2'b10);
    wire [63:0] predicted_target = btb_tgt[pred_idx];

    wire fetch_slot0_pairable =
        writes_register(fetch_opcode0) &&
        !fetch_is_branch0 &&
        (fetch_opcode0 != OP_MOV_ML) &&
        (fetch_opcode0 != OP_PRIV);
    wire fetch_slot1_pairable =
        writes_register(fetch_opcode1) &&
        !fetch_is_branch1 &&
        (fetch_opcode1 != OP_MOV_ML) &&
        (fetch_opcode1 != OP_PRIV);

    wire can_dual_issue_fetch =
        fetch_slot0_pairable &&
        fetch_slot1_pairable &&
        !same_packet_raw(fetch_opcode0, fetch_rd0, fetch_opcode1, fetch_rs1, fetch_rt1, fetch_rd1) &&
        !(writes_register(fetch_opcode0) && writes_register(fetch_opcode1) && (fetch_rd0 == fetch_rd1));

    wire [63:0] fetch_next_pc = predict_takenRaw ? predicted_target :
                                can_dual_issue_fetch ? (pc + 64'd8) :
                                (pc + 64'd4);

    reg if_id_predicted_taken;
    reg [63:0] if_id_predicted_target;

    wire [63:0] mem_wdata = (mem_opcode == OP_CALL) ? (mem_pc + 64'd4) : mem_store_data;
    wire mem_read = ex2_mem_valid && (mem_opcode == OP_MOV_ML || mem_opcode == OP_RET);
    wire mem_write = ex2_mem_valid && (mem_opcode == OP_MOV_SM || mem_opcode == OP_CALL);
    wire sb_retire_ready = (sb_count > 0) && !mem_read;
    wire [63:0] phys_addr = mem_read ? mem_addr : sb_addr[sb_head];

    memory memory (
        .clk(clk),
        .addr(phys_addr),
        .write_data(sb_data[sb_head]),
        .mem_write(sb_retire_ready),
        .mem_read(mem_read),
        .read_data(mem_read_data)
    );

    assign reg_write_en = ex2_mem_valid && writes_register(mem_opcode);
    assign reg_write_rd = mem_phys_rd;
    assign reg_write_en1 = ex2_mem_valid1 && writes_register(mem_opcode1);
    assign reg_write_rd1 = mem_phys_rd1;

    always @(*) begin
        take_branch = 1'b0;
        branch_target = 64'b0;

        if (ex1_ex2_valid && ex2_is_branch) begin
            case (ex2_opcode)
                OP_BR: begin
                    take_branch = 1'b1;
                    branch_target = ex2_RD_LATCH;
                end
                OP_BRR_R: begin
                    take_branch = 1'b1;
                    branch_target = ex2_pc + ex2_RD_LATCH;
                end
                OP_BRR_L: begin
                    take_branch = 1'b1;
                    branch_target = ex2_pc + {{52{ex2_imm[11]}}, ex2_imm};
                end
                OP_BRNZ: begin
                    if (ex2_A != 0) begin
                        take_branch = 1'b1;
                        branch_target = ex2_RD_LATCH;
                    end
                end
                OP_CALL: begin
                    take_branch = 1'b1;
                    branch_target = ex2_RD_LATCH;
                end
                OP_BRGT: begin
                    if ($signed(ex2_A) > $signed(ex2_B)) begin
                        take_branch = 1'b1;
                        branch_target = ex2_RD_LATCH;
                    end
                end
            endcase
        end
    end

    wire sb_full = (sb_count == 3'd4);
    wire sb_stall = ex2_mem_valid && mem_write && sb_full;

    wire rs_forwardable = (rs_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rs_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rs_phys) ||
        (mem_wb_valid && wb_phys_rd == rs_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rs_phys) ||
        (fpu_done && fpu_phys_rd_out == rs_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rs_phys);
    
    wire rt_forwardable = (rt_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rt_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rt_phys) ||
        (mem_wb_valid && wb_phys_rd == rt_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rt_phys) ||
        (fpu_done && fpu_phys_rd_out == rt_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rt_phys);

    wire rd_src_forwardable = (rd_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rd_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rd_phys) ||
        (mem_wb_valid && wb_phys_rd == rd_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rd_phys) ||
        (fpu_done && fpu_phys_rd_out == rd_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rd_phys);

    wire rs1_forwardable = (rs1_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rs1_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rs1_phys) ||
        (mem_wb_valid && wb_phys_rd == rs1_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rs1_phys) ||
        (fpu_done && fpu_phys_rd_out == rs1_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rs1_phys);

    wire rt1_forwardable = (rt1_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rt1_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rt1_phys) ||
        (mem_wb_valid && wb_phys_rd == rt1_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rt1_phys) ||
        (fpu_done && fpu_phys_rd_out == rt1_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rt1_phys);

    wire rd1_src_forwardable = (rd1_phys == 0) ||
        (ex2_mem_valid && mem_phys_rd == rd1_phys) ||
        (ex2_mem_valid1 && mem_phys_rd1 == rd1_phys) ||
        (mem_wb_valid && wb_phys_rd == rd1_phys) ||
        (mem_wb_valid1 && wb_phys_rd1 == rd1_phys) ||
        (fpu_done && fpu_phys_rd_out == rd1_phys) ||
        (fpu_done1 && fpu1_phys_rd_out == rd1_phys);

    wire src_hazard0 =
        if_id_valid &&
        ((uses_rs(opcode) && rs_phys != 0 && phys_busy[rs_phys] && !rs_forwardable) ||
         (uses_rt(opcode) && rt_phys != 0 && phys_busy[rt_phys] && !rt_forwardable) ||
         (uses_rd_source(opcode) && rd_phys != 0 && phys_busy[rd_phys] && !rd_src_forwardable));

    wire src_hazard1 =
        if_id_valid1 &&
        ((uses_rs(opcode1) && rs1_phys != 0 && phys_busy[rs1_phys] && !rs1_forwardable) ||
         (uses_rt(opcode1) && rt1_phys != 0 && phys_busy[rt1_phys] && !rt1_forwardable) ||
         (uses_rd_source(opcode1) && rd1_phys != 0 && phys_busy[rd1_phys] && !rd1_src_forwardable));

    wire decode_hazard = src_hazard0 || src_hazard1;

    wire ex2_waiting_for_alu = ex2_needs_alu_pipe && (!ex2_long_op_started || !ex2_long_op_complete);
    wire ex2_waiting_for_alu1 = ex2_needs_alu_pipe1 && (!ex2_long_op_started1 || !ex2_long_op_complete1);
    wire alu_busy_stall = ex2_waiting_for_alu || ex2_waiting_for_alu1;

    wire pipeline_stall = decode_hazard || rename_stall || sb_stall || alu_busy_stall;
    wire halt_in_ex2 = ex1_ex2_valid && (ex2_opcode == OP_PRIV) && (ex2_imm == 12'b0);

    wire ex_mispredicted = (take_branch != ex2_predicted_taken) || (take_branch && (branch_target != ex2_predicted_target));
    wire ex_control_flush = ex1_ex2_valid && ex2_is_branch && (ex2_opcode != OP_RET) && ex_mispredicted;
    wire mem_control_flush = ex2_mem_valid && (mem_opcode == OP_RET);

    always @(posedge clk) begin
        if (reset) begin
            pc <= 64'h2000;
            hlt <= 1'b0;
            halt_pending <= 1'b0;

            if_id_valid <= 1'b0;
            if_id_pc <= 64'b0;
            if_id_instr <= 32'b0;
            if_id_valid1 <= 1'b0;
            if_id_pc1 <= 64'b0;
            if_id_instr1 <= 32'b0;
            if_id_predicted_taken <= 1'b0;
            if_id_predicted_target <= 64'b0;

            id_ex1_valid <= 1'b0;
            ex1_pc <= 64'b0;
            ex1_opcode <= 5'b0;
            ex1_rd <= 5'b0;
            ex1_rs <= 5'b0;
            ex1_rt <= 5'b0;
            ex1_imm <= 12'b0;
            ex1_use_immediate <= 1'b0;
            ex1_use_fpu_instruction <= 1'b0;
            ex1_is_branch <= 1'b0;
            ex1_predicted_taken <= 1'b0;
            ex1_predicted_target <= 64'b0;
            ex1_phys_rd <= 6'b0;
            id_ex1_valid1 <= 1'b0;
            ex1_pc1 <= 64'b0;
            ex1_opcode1 <= 5'b0;
            ex1_rd1 <= 5'b0;
            ex1_rs1 <= 5'b0;
            ex1_rt1 <= 5'b0;
            ex1_imm1 <= 12'b0;
            ex1_use_immediate1 <= 1'b0;
            ex1_use_fpu_instruction1 <= 1'b0;
            ex1_phys_rd1 <= 6'b0;

            ex1_ex2_valid <= 1'b0;
            ex2_pc <= 64'b0;
            ex2_opcode <= 5'b0;
            ex2_rd <= 5'b0;
            ex2_A <= 64'b0;
            ex2_B <= 64'b0;
            ex2_RD_LATCH <= 64'b0;
            ex2_imm <= 12'b0;
            ex2_use_immediate <= 1'b0;
            ex2_use_fpu_instruction <= 1'b0;
            ex2_is_branch <= 1'b0;
            ex2_predicted_taken <= 1'b0;
            ex2_predicted_target <= 64'b0;
            ex2_long_op_started <= 1'b0;
            ex2_long_op_complete <= 1'b0;
            ex2_phys_rd <= 6'b0;
            ex1_ex2_valid1 <= 1'b0;
            ex2_pc1 <= 64'b0;
            ex2_opcode1 <= 5'b0;
            ex2_rd1 <= 5'b0;
            ex2_A1 <= 64'b0;
            ex2_B1 <= 64'b0;
            ex2_RD_LATCH1 <= 64'b0;
            ex2_imm1 <= 12'b0;
            ex2_use_immediate1 <= 1'b0;
            ex2_use_fpu_instruction1 <= 1'b0;
            ex2_long_op_started1 <= 1'b0;
            ex2_long_op_complete1 <= 1'b0;
            ex2_phys_rd1 <= 6'b0;

            ex2_mem_valid <= 1'b0;
            mem_pc <= 64'b0;
            mem_opcode <= 5'b0;
            mem_rd <= 5'b0;
            mem_phys_rd <= 6'b0;
            mem_store_data <= 64'b0;
            ex2_mem_valid1 <= 1'b0;
            mem_pc1 <= 64'b0;
            mem_opcode1 <= 5'b0;
            mem_rd1 <= 5'b0;
            mem_phys_rd1 <= 6'b0;

            mem_wb_valid <= 1'b0;
            wb_opcode <= 5'b0;
            wb_rd <= 5'b0;
            wb_phys_rd <= 6'b0;
            wb_alu_out <= 64'b0;
            wb_fpu_out <= 64'b0;
            mem_wb_valid1 <= 1'b0;
            wb_opcode1 <= 5'b0;
            wb_rd1 <= 5'b0;
            wb_phys_rd1 <= 6'b0;
            wb_alu_out1 <= 64'b0;
            wb_fpu_out1 <= 64'b0;

            A <= 64'b0;
            B <= 64'b0;
            RD_LATCH <= 64'b0;
            A1 <= 64'b0;
            B1 <= 64'b0;
            RD_LATCH1 <= 64'b0;
            ALUOut <= 64'b0;
            FPUOut <= 64'b0;
            ALUOut1 <= 64'b0;
            FPUOut1 <= 64'b0;
            MDR <= 64'b0;

            btb_valid <= 64'b0;
            for (i = 0; i < 64; i = i + 1) begin
                bht[i] <= 2'b01;
                btb_tgt[i] <= 64'b0;
                btb_tag[i] <= 52'b0;
            end

            sb_head <= 2'b0;
            sb_tail <= 2'b0;
            sb_count <= 3'b0;
            sb_valid <= 4'b0;
            for (i = 0; i < 4; i = i + 1) begin
                sb_addr[i] <= 64'b0;
                sb_data[i] <= 64'b0;
            end
        end else if (hlt) begin
            if_id_valid <= 1'b0;
            if_id_valid1 <= 1'b0;
            id_ex1_valid <= 1'b0;
            id_ex1_valid1 <= 1'b0;
            ex1_ex2_valid <= 1'b0;
            ex1_ex2_valid1 <= 1'b0;
            ex2_mem_valid <= 1'b0;
            ex2_mem_valid1 <= 1'b0;
            mem_wb_valid <= 1'b0;
            mem_wb_valid1 <= 1'b0;
        end else begin
            if (halt_in_ex2) begin
                halt_pending <= 1'b1;
            end

            if (halt_pending &&
                (sb_count == 3'b0) &&
                !ex2_mem_valid &&
                !ex2_mem_valid1 &&
                !mem_wb_valid &&
                !mem_wb_valid1 &&
                !fpu_busy && !fpu_busy1 &&
                !(ex2_mem_valid && mem_write)) begin
                $display("Execution Halted.");
                hlt <= 1'b1;
            end

            if (mem_control_flush) begin
                pc <= mem_read_data;
            end else if (ex_control_flush) begin
                pc <= take_branch ? branch_target : (ex2_pc + 64'd4);
            end else if (!pipeline_stall && !halt_in_ex2 && !halt_pending) begin
                pc <= fetch_next_pc;
            end

            if (mem_control_flush || ex_control_flush || halt_in_ex2 || halt_pending) begin
                if_id_valid <= 1'b0;
                if_id_pc <= 64'b0;
                if_id_instr <= 32'b0;
                if_id_valid1 <= 1'b0;
                if_id_pc1 <= 64'b0;
                if_id_instr1 <= 32'b0;
                if_id_predicted_taken <= 1'b0;
                if_id_predicted_target <= 64'b0;
            end else if (!pipeline_stall) begin
                if_id_valid <= 1'b1;
                if_id_pc <= pc;
                if_id_instr <= fetch_instr0;
                if_id_valid1 <= can_dual_issue_fetch;
                if_id_pc1 <= pc + 64'd4;
                if_id_instr1 <= fetch_instr1;
                if_id_predicted_taken <= predict_takenRaw && !can_dual_issue_fetch;
                if_id_predicted_target <= predicted_target;
            end

            if (mem_control_flush || ex_control_flush || halt_in_ex2 || halt_pending) begin
                id_ex1_valid <= 1'b0;
                ex1_pc <= 64'b0;
                ex1_opcode <= 5'b0;
                ex1_rd <= 5'b0;
                ex1_rs <= 5'b0;
                ex1_rt <= 5'b0;
                ex1_imm <= 12'b0;
                ex1_use_immediate <= 1'b0;
                ex1_use_fpu_instruction <= 1'b0;
                ex1_is_branch <= 1'b0;
                ex1_predicted_taken <= 1'b0;
                ex1_predicted_target <= 64'b0;
                ex1_phys_rd <= 6'b0;
                A <= 64'b0;
                B <= 64'b0;
                RD_LATCH <= 64'b0;

                id_ex1_valid1 <= 1'b0;
                ex1_pc1 <= 64'b0;
                ex1_opcode1 <= 5'b0;
                ex1_rd1 <= 5'b0;
                ex1_rs1 <= 5'b0;
                ex1_rt1 <= 5'b0;
                ex1_imm1 <= 12'b0;
                ex1_use_immediate1 <= 1'b0;
                ex1_use_fpu_instruction1 <= 1'b0;
                ex1_phys_rd1 <= 6'b0;
                A1 <= 64'b0;
                B1 <= 64'b0;
                RD_LATCH1 <= 64'b0;
            end else if ((decode_hazard || rename_stall) && !alu_busy_stall && !sb_stall) begin
                id_ex1_valid <= 1'b0;
                ex1_pc <= 64'b0;
                ex1_opcode <= 5'b0;
                ex1_rd <= 5'b0;
                ex1_rs <= 5'b0;
                ex1_rt <= 5'b0;
                ex1_imm <= 12'b0;
                ex1_use_immediate <= 1'b0;
                ex1_use_fpu_instruction <= 1'b0;
                ex1_is_branch <= 1'b0;
                ex1_predicted_taken <= 1'b0;
                ex1_predicted_target <= 64'b0;
                ex1_phys_rd <= 6'b0;
                A <= 64'b0;
                B <= 64'b0;
                RD_LATCH <= 64'b0;

                id_ex1_valid1 <= 1'b0;
                ex1_pc1 <= 64'b0;
                ex1_opcode1 <= 5'b0;
                ex1_rd1 <= 5'b0;
                ex1_rs1 <= 5'b0;
                ex1_rt1 <= 5'b0;
                ex1_imm1 <= 12'b0;
                ex1_use_immediate1 <= 1'b0;
                ex1_use_fpu_instruction1 <= 1'b0;
                ex1_phys_rd1 <= 6'b0;
                A1 <= 64'b0;
                B1 <= 64'b0;
                RD_LATCH1 <= 64'b0;
            end else if (!pipeline_stall) begin
                id_ex1_valid <= if_id_valid;
                ex1_pc <= if_id_pc;
                ex1_opcode <= opcode;
                ex1_rd <= rd;
                ex1_rs <= rs;
                ex1_rt <= rt;
                ex1_imm <= imm;
                ex1_use_immediate <= use_immediate;
                ex1_use_fpu_instruction <= use_fpu_instruction;
                ex1_is_branch <= is_branch;
                ex1_predicted_taken <= if_id_predicted_taken;
                ex1_predicted_target <= if_id_predicted_target;
                ex1_phys_rd <= writes_register(opcode) ? alloc_phys0 : 6'b0;
                // Forwarding for Slot 0
                A <= rs_val;
                if (if_id_valid && uses_rs(opcode) && rs_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rs_phys) A <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rs_phys) A <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rs_phys) A <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rs_phys) A <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rs_phys) A <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rs_phys) A <= fpu_res1;
                end

                B <= rt_val;
                if (if_id_valid && uses_rt(opcode) && rt_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rt_phys) B <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rt_phys) B <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rt_phys) B <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rt_phys) B <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rt_phys) B <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rt_phys) B <= fpu_res1;
                end

                RD_LATCH <= rd_val;
                if (if_id_valid && uses_rd_source(opcode) && rd_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rd_phys) RD_LATCH <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rd_phys) RD_LATCH <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rd_phys) RD_LATCH <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rd_phys) RD_LATCH <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rd_phys) RD_LATCH <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rd_phys) RD_LATCH <= fpu_res1;
                end

                id_ex1_valid1 <= if_id_valid1 && decode_pairable_packet;
                ex1_pc1 <= if_id_pc1;
                ex1_opcode1 <= opcode1;
                ex1_rd1 <= rd1;
                ex1_rs1 <= rs1;
                ex1_rt1 <= rt1;
                ex1_imm1 <= imm1;
                ex1_use_immediate1 <= use_immediate1;
                ex1_use_fpu_instruction1 <= use_fpu_instruction1;
                ex1_phys_rd1 <= writes_register(opcode1) ? alloc_phys1 : 6'b0;
                // Forwarding for Slot 1
                A1 <= rs1_val;
                if (if_id_valid1 && uses_rs(opcode1) && rs1_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rs1_phys) A1 <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rs1_phys) A1 <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rs1_phys) A1 <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rs1_phys) A1 <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rs1_phys) A1 <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rs1_phys) A1 <= fpu_res1;
                end

                B1 <= rt1_val;
                if (if_id_valid1 && uses_rt(opcode1) && rt1_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rt1_phys) B1 <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rt1_phys) B1 <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rt1_phys) B1 <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rt1_phys) B1 <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rt1_phys) B1 <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rt1_phys) B1 <= fpu_res1;
                end

                RD_LATCH1 <= rd1_val;
                if (if_id_valid1 && uses_rd_source(opcode1) && rd1_phys != 0) begin
                    if (ex2_mem_valid && mem_phys_rd == rd1_phys) RD_LATCH1 <= reg_write_data;
                    else if (ex2_mem_valid1 && mem_phys_rd1 == rd1_phys) RD_LATCH1 <= reg_write_data1;
                    else if (mem_wb_valid && wb_phys_rd == rd1_phys) RD_LATCH1 <= wb_alu_out;
                    else if (mem_wb_valid1 && wb_phys_rd1 == rd1_phys) RD_LATCH1 <= wb_alu_out1;
                    else if (fpu_done && fpu_phys_rd_out == rd1_phys) RD_LATCH1 <= fpu_res;
                    else if (fpu_done1 && fpu1_phys_rd_out == rd1_phys) RD_LATCH1 <= fpu_res1;
                end
            end

            if (mem_control_flush || ex_control_flush || halt_in_ex2 || halt_pending) begin
                ex1_ex2_valid <= 1'b0;
                ex2_pc <= 64'b0;
                ex2_opcode <= 5'b0;
                ex2_rd <= 5'b0;
                ex2_A <= 64'b0;
                ex2_B <= 64'b0;
                ex2_RD_LATCH <= 64'b0;
                ex2_imm <= 12'b0;
                ex2_use_immediate <= 1'b0;
                ex2_use_fpu_instruction <= 1'b0;
                ex2_is_branch <= 1'b0;
                ex2_predicted_taken <= 1'b0;
                ex2_predicted_target <= 64'b0;
                ex2_long_op_started <= 1'b0;
                ex2_long_op_complete <= 1'b0;
                ex2_phys_rd <= 6'b0;

                ex1_ex2_valid1 <= 1'b0;
                ex2_pc1 <= 64'b0;
                ex2_opcode1 <= 5'b0;
                ex2_rd1 <= 5'b0;
                ex2_A1 <= 64'b0;
                ex2_B1 <= 64'b0;
                ex2_RD_LATCH1 <= 64'b0;
                ex2_imm1 <= 12'b0;
                ex2_use_immediate1 <= 1'b0;
                ex2_use_fpu_instruction1 <= 1'b0;
                ex2_long_op_started1 <= 1'b0;
                ex2_long_op_complete1 <= 1'b0;
                ex2_phys_rd1 <= 6'b0;
            end else if (alu_busy_stall) begin
            end else begin
                ex1_ex2_valid <= id_ex1_valid;
                ex2_pc <= ex1_pc;
                ex2_opcode <= ex1_opcode;
                ex2_rd <= ex1_rd;
                ex2_A <= A;
                ex2_B <= B;
                ex2_RD_LATCH <= RD_LATCH;
                ex2_imm <= ex1_imm;
                ex2_use_immediate <= ex1_use_immediate;
                ex2_use_fpu_instruction <= ex1_use_fpu_instruction;
                ex2_is_branch <= ex1_is_branch;
                ex2_predicted_taken <= ex1_predicted_taken;
                ex2_predicted_target <= ex1_predicted_target;
                ex2_long_op_started <= 1'b0;
                ex2_long_op_complete <= 1'b0;
                ex2_phys_rd <= ex1_phys_rd;

                ex1_ex2_valid1 <= id_ex1_valid1;
                ex2_pc1 <= ex1_pc1;
                ex2_opcode1 <= ex1_opcode1;
                ex2_rd1 <= ex1_rd1;
                ex2_A1 <= A1;
                ex2_B1 <= B1;
                ex2_RD_LATCH1 <= RD_LATCH1;
                ex2_imm1 <= ex1_imm1;
                ex2_use_immediate1 <= ex1_use_immediate1;
                ex2_use_fpu_instruction1 <= ex1_use_fpu_instruction1;
                ex2_long_op_started1 <= 1'b0;
                ex2_long_op_complete1 <= 1'b0;
                ex2_phys_rd1 <= ex1_phys_rd1;
            end

            if (ex1_ex2_valid && (alu_start || fpu_start)) begin
                ex2_long_op_started <= 1'b1;
            end
            if (ex1_ex2_valid1 && (alu_start1 || fpu_start1)) begin
                ex2_long_op_started1 <= 1'b1;
            end
            if (alu_done || fpu_done) begin
                ex2_long_op_complete <= 1'b1;
            end
            if (alu_done1 || fpu_done1) begin
                ex2_long_op_complete1 <= 1'b1;
            end

            if (mem_control_flush || halt_in_ex2) begin
                ex2_mem_valid <= 1'b0;
                mem_pc <= 64'b0;
                mem_opcode <= 5'b0;
                mem_rd <= 5'b0;
                mem_phys_rd <= 6'b0;
                mem_store_data <= 64'b0;
                ALUOut <= 64'b0;
                FPUOut <= 64'b0;
                ex2_mem_valid1 <= 1'b0;
                mem_pc1 <= 64'b0;
                mem_opcode1 <= 5'b0;
                mem_rd1 <= 5'b0;
                mem_phys_rd1 <= 6'b0;
                ALUOut1 <= 64'b0;
                FPUOut1 <= 64'b0;
            end else begin
                if (ex1_ex2_valid && ex2_is_branch && ex2_opcode != OP_CALL && ex2_opcode != OP_RET) begin
                    ex2_mem_valid <= 1'b0;
                    mem_pc <= 64'b0;
                    mem_opcode <= 5'b0;
                    mem_rd <= 5'b0;
                    mem_phys_rd <= 6'b0;
                    mem_store_data <= 64'b0;
                    ALUOut <= 64'b0;
                    FPUOut <= 64'b0;
                    ex2_mem_valid1 <= 1'b0;
                    mem_pc1 <= 64'b0;
                    mem_opcode1 <= 5'b0;
                    mem_rd1 <= 5'b0;
                    mem_phys_rd1 <= 6'b0;
                    ALUOut1 <= 64'b0;
                    FPUOut1 <= 64'b0;
                end else if (sb_stall || alu_busy_stall) begin
                    // Case where we are stalling due to integer MUL/DIV
                end else begin
                    // MOVE TO MEM
                    ex2_mem_valid <= ex1_ex2_valid;
                    mem_pc <= ex2_pc;
                    mem_opcode <= ex2_opcode;
                    mem_rd <= ex2_rd;
                    mem_phys_rd <= ex2_phys_rd;
                    mem_store_data <= ex2_A;
                    ALUOut <= alu_res;
                    FPUOut <= fpu_res;

                    ex2_mem_valid1 <= ex1_ex2_valid1;
                    mem_pc1 <= ex2_pc1;
                    mem_opcode1 <= ex2_opcode1;
                    mem_rd1 <= ex2_rd1;
                    mem_phys_rd1 <= ex2_phys_rd1;
                    ALUOut1 <= alu_res1;
                    FPUOut1 <= fpu_res1;
                end
            end

            if (halt_in_ex2 || halt_pending) begin
                mem_wb_valid <= 1'b0;
                wb_opcode <= 5'b0;
                wb_rd <= 5'b0;
                wb_phys_rd <= 6'b0;
                wb_alu_out <= 64'b0;
                wb_fpu_out <= 64'b0;
                mem_wb_valid1 <= 1'b0;
                wb_opcode1 <= 5'b0;
                wb_rd1 <= 5'b0;
                wb_phys_rd1 <= 6'b0;
                wb_alu_out1 <= 64'b0;
                wb_fpu_out1 <= 64'b0;
                MDR <= 64'b0;
            end else begin
                mem_wb_valid <= ex2_mem_valid && writes_register(mem_opcode);
                wb_opcode <= mem_opcode;
                wb_rd <= mem_rd;
                wb_phys_rd <= mem_phys_rd;
                wb_alu_out <= ALUOut;
                wb_fpu_out <= FPUOut;
                mem_wb_valid1 <= ex2_mem_valid1 && writes_register(mem_opcode1);
                wb_opcode1 <= mem_opcode1;
                wb_rd1 <= mem_rd1;
                wb_phys_rd1 <= mem_phys_rd1;
                wb_alu_out1 <= ALUOut1;
                wb_fpu_out1 <= FPUOut1;
                MDR <= forwarded_mem_read_data;
            end

            if (ex1_ex2_valid && ex2_is_branch && ex2_opcode != OP_RET) begin
                if (take_branch) begin
                    if (bht[ex2_pc[7:2]] != 2'b11) bht[ex2_pc[7:2]] <= bht[ex2_pc[7:2]] + 2'b01;
                end else begin
                    if (bht[ex2_pc[7:2]] != 2'b00) bht[ex2_pc[7:2]] <= bht[ex2_pc[7:2]] - 2'b01;
                end
                if (take_branch) begin
                    btb_tgt[ex2_pc[7:2]] <= branch_target;
                    btb_tag[ex2_pc[7:2]] <= ex2_pc[63:12];
                    btb_valid[ex2_pc[7:2]] <= 1'b1;
                end
            end

            if (sb_retire_ready) begin
                sb_valid[sb_head] <= 1'b0;
                sb_head <= sb_head + 2'b1;
                if (!(ex2_mem_valid && mem_write && !sb_full)) begin
                    sb_count <= sb_count - 3'b1;
                end
            end

            if (ex2_mem_valid && mem_write && !sb_full) begin
                sb_addr[sb_tail] <= mem_addr;
                sb_data[sb_tail] <= mem_wdata;
                sb_valid[sb_tail] <= 1'b1;
                sb_tail <= sb_tail + 2'b1;
                if (!sb_retire_ready) begin
                    sb_count <= sb_count + 3'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        reg [5:0] old_amt0;
        reg [5:0] old_amt1;
        if (reset) begin
            temp_free <= 32'hFFFF_FFFF;
            phys_busy <= 64'b0;
            for (i = 0; i < 32; i = i + 1) begin
                rat[i] <= i[5:0];
                amt[i] <= i[5:0];
            end
        end else begin
            if (commit_en0) begin
                old_amt0 = amt[mem_rd];
                amt[mem_rd] <= mem_phys_rd;
                if (rat[mem_rd] == old_amt0)
                    rat[mem_rd] <= mem_phys_rd;
                if (old_amt0 >= 6'd32)
                    temp_free[old_amt0 - 6'd32] <= 1'b1;
            end

            if (commit_en1) begin
                old_amt1 = amt[mem_rd1];
                amt[mem_rd1] <= mem_phys_rd1;
                if (rat[mem_rd1] == old_amt1)
                    rat[mem_rd1] <= mem_phys_rd1;
                if (old_amt1 >= 6'd32)
                    temp_free[old_amt1 - 6'd32] <= 1'b1;
            end

            if (mem_wb_valid && (wb_opcode < 5'h14 || wb_opcode > 5'h17))
                phys_busy[wb_phys_rd] <= 1'b0;
            if (mem_wb_valid1 && (wb_opcode1 < 5'h14 || wb_opcode1 > 5'h17))
                phys_busy[wb_phys_rd1] <= 1'b0;

            if (fpu_done)
                phys_busy[fpu_phys_rd_out] <= 1'b0;
            if (fpu_done1)
                phys_busy[fpu1_phys_rd_out] <= 1'b0;

            if (mem_control_flush || ex_control_flush || halt_in_ex2 || halt_pending) begin
                temp_free <= 32'hFFFF_FFFF;
                phys_busy <= 64'b0;

                for (i = 0; i < 32; i = i + 1) begin
                    rat[i] <= amt[i];
                    if (amt[i] >= 6'd32)
                        temp_free[amt[i] - 6'd32] <= 1'b0;
                end

                if (ex2_mem_valid && writes_register(mem_opcode) && (mem_phys_rd >= 6'd32))
                    temp_free[mem_phys_rd - 6'd32] <= 1'b0;
                if (ex2_mem_valid1 && writes_register(mem_opcode1) && (mem_phys_rd1 >= 6'd32))
                    temp_free[mem_phys_rd1 - 6'd32] <= 1'b0;
                if (mem_wb_valid && (wb_phys_rd >= 6'd32))
                    temp_free[wb_phys_rd - 6'd32] <= 1'b0;
                if (mem_wb_valid1 && (wb_phys_rd1 >= 6'd32))
                    temp_free[wb_phys_rd1 - 6'd32] <= 1'b0;
            end else if (!pipeline_stall) begin
                if (if_id_valid && writes_register(opcode)) begin
                    rat[rd] <= alloc_phys0;
                    temp_free[alloc_phys0 - 6'd32] <= 1'b0;
                    phys_busy[alloc_phys0] <= 1'b1;
                end

                if (if_id_valid1 && decode_pairable_packet && writes_register(opcode1)) begin
                    rat[rd1] <= alloc_phys1;
                    temp_free[alloc_phys1 - 6'd32] <= 1'b0;
                    phys_busy[alloc_phys1] <= 1'b1;
                end
            end
        end
    end
endmodule
