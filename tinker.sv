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

    reg [63:0] pc;

    reg if_id_valid;
    reg [63:0] if_id_pc;
    reg [31:0] if_id_instr;

    reg id_ex_valid;
    reg [63:0] ex_pc;
    reg [4:0] ex_opcode;
    reg [4:0] ex_rd;
    reg [4:0] ex_rs;
    reg [4:0] ex_rt;
    reg [11:0] ex_imm;
    reg ex_use_immediate;
    reg ex_use_fpu_instruction;
    reg ex_is_branch;

    reg ex_mem_valid;
    reg [63:0] mem_pc;
    reg [4:0] mem_opcode;
    reg [4:0] mem_rd;
    reg [63:0] mem_store_data;

    reg mem_wb_valid;
    reg [4:0] wb_opcode;
    reg [4:0] wb_rd;
    reg [63:0] wb_alu_out;
    reg [63:0] wb_fpu_out;

    wire [31:0] IR = if_id_instr;

    reg [63:0] A;
    reg [63:0] B;
    reg [63:0] RD_LATCH;
    reg [63:0] ALUOut;
    reg [63:0] FPUOut;
    reg [63:0] MDR;

    wire [4:0] opcode;
    wire [4:0] rd;
    wire [4:0] rs;
    wire [4:0] rt;
    wire [11:0] imm;
    wire use_immediate;
    wire use_fpu_instruction;
    wire is_branch;

    instruction_decoder decoder (
        .instruction(IR),
        .opcode(opcode),
        .rd(rd),
        .rs(rs),
        .rt(rt),
        .imm(imm),
        .use_immediate(use_immediate),
        .use_fpu_instruction(use_fpu_instruction),
        .is_branch(is_branch)
    );

    wire [63:0] rd_val;
    wire [63:0] rs_val;
    wire [63:0] rt_val;
    wire [63:0] r31_val;
    wire [63:0] reg_write_data;
    wire reg_write_en;

    register_file reg_file (
        .clk(clk),
        .reset(reset),
        .data(reg_write_data),
        .rd(rd),
        .rs(rs),
        .rt(rt),
        .write_rd(wb_rd),
        .write_enable(reg_write_en),
        .rd_val(rd_val),
        .rs_val(rs_val),
        .rt_val(rt_val),
        .r31_val(r31_val)
    );

    wire [63:0] alu_input_a = uses_rd_as_alu_a(ex_opcode) ? RD_LATCH : A;
    wire [63:0] alu_input_b = ex_use_immediate ? extend_imm(ex_opcode, ex_imm) : B;
    wire [63:0] alu_res;
    wire [63:0] fpu_res;

    ALU alu (
        .a(alu_input_a),
        .b(alu_input_b),
        .op(ex_opcode),
        .res(alu_res)
    );

    FPU fpu (
        .a(A),
        .b(alu_input_b),
        .op(ex_opcode),
        .res(fpu_res)
    );

    wire [63:0] stack_addr = r31_val - 64'd8;
    wire [63:0] mem_addr = (mem_opcode == OP_CALL || mem_opcode == OP_RET) ? stack_addr : ALUOut;
    wire [63:0] mem_wdata = (mem_opcode == OP_CALL) ? (mem_pc + 64'd4) : mem_store_data;
    wire mem_read = ex_mem_valid && (mem_opcode == OP_MOV_ML || mem_opcode == OP_RET);
    wire mem_write = ex_mem_valid && (mem_opcode == OP_MOV_SM || mem_opcode == OP_CALL);
    wire [63:0] mem_read_data;

    memory memory (
        .clk(clk),
        .addr(mem_addr),
        .write_data(mem_wdata),
        .mem_write(mem_write),
        .mem_read(mem_read),
        .read_data(mem_read_data)
    );

    assign reg_write_en = mem_wb_valid && writes_register(wb_opcode);
    assign reg_write_data = (wb_opcode == OP_MOV_ML) ? MDR :
                            (wb_opcode >= OP_ADDF && wb_opcode <= OP_DIVF) ? wb_fpu_out :
                            wb_alu_out;

    reg take_branch;
    reg [63:0] branch_target;

    always @(*) begin
        take_branch = 1'b0;
        branch_target = 64'b0;

        if (id_ex_valid && ex_is_branch) begin
            case (ex_opcode)
                OP_BR: begin
                    take_branch = 1'b1;
                    branch_target = RD_LATCH;
                end
                OP_BRR_R: begin
                    take_branch = 1'b1;
                    branch_target = ex_pc + RD_LATCH;
                end
                OP_BRR_L: begin
                    take_branch = 1'b1;
                    branch_target = ex_pc + {{52{ex_imm[11]}}, ex_imm};
                end
                OP_BRNZ: begin
                    if (A != 0) begin
                        take_branch = 1'b1;
                        branch_target = RD_LATCH;
                    end
                end
                OP_CALL: begin
                    take_branch = 1'b1;
                    branch_target = RD_LATCH;
                end
                OP_BRGT: begin
                    if (A > B) begin
                        take_branch = 1'b1;
                        branch_target = RD_LATCH;
                    end
                end
            endcase
        end
    end

    wire hazard_on_rs = uses_rs(opcode) && (
        (id_ex_valid && writes_register(ex_opcode) && (rs == ex_rd)) ||
        (ex_mem_valid && writes_register(mem_opcode) && (rs == mem_rd)) ||
        (mem_wb_valid && writes_register(wb_opcode) && (rs == wb_rd))
    );

    wire hazard_on_rt = uses_rt(opcode) && (
        (id_ex_valid && writes_register(ex_opcode) && (rt == ex_rd)) ||
        (ex_mem_valid && writes_register(mem_opcode) && (rt == mem_rd)) ||
        (mem_wb_valid && writes_register(wb_opcode) && (rt == wb_rd))
    );

    wire hazard_on_rd = uses_rd_source(opcode) && (
        (id_ex_valid && writes_register(ex_opcode) && (rd == ex_rd)) ||
        (ex_mem_valid && writes_register(mem_opcode) && (rd == mem_rd)) ||
        (mem_wb_valid && writes_register(wb_opcode) && (rd == wb_rd))
    );

    wire hazard_stall = if_id_valid && (hazard_on_rs || hazard_on_rt || hazard_on_rd);
    wire halt_in_ex = id_ex_valid && (ex_opcode == OP_PRIV) && (ex_imm == 12'b0);
    wire ex_control_flush = id_ex_valid && ex_is_branch && (ex_opcode != OP_RET) && take_branch;
    wire mem_control_flush = ex_mem_valid && (mem_opcode == OP_RET);

    always @(posedge clk) begin
        if (reset) begin
            pc <= 64'h2000;
            hlt <= 1'b0;

            if_id_valid <= 1'b0;
            if_id_pc <= 64'b0;
            if_id_instr <= 32'b0;

            id_ex_valid <= 1'b0;
            ex_pc <= 64'b0;
            ex_opcode <= 5'b0;
            ex_rd <= 5'b0;
            ex_rs <= 5'b0;
            ex_rt <= 5'b0;
            ex_imm <= 12'b0;
            ex_use_immediate <= 1'b0;
            ex_use_fpu_instruction <= 1'b0;
            ex_is_branch <= 1'b0;

            ex_mem_valid <= 1'b0;
            mem_pc <= 64'b0;
            mem_opcode <= 5'b0;
            mem_rd <= 5'b0;
            mem_store_data <= 64'b0;

            mem_wb_valid <= 1'b0;
            wb_opcode <= 5'b0;
            wb_rd <= 5'b0;
            wb_alu_out <= 64'b0;
            wb_fpu_out <= 64'b0;

            A <= 64'b0;
            B <= 64'b0;
            RD_LATCH <= 64'b0;
            ALUOut <= 64'b0;
            FPUOut <= 64'b0;
            MDR <= 64'b0;
        end else if (hlt) begin
            if_id_valid <= 1'b0;
            id_ex_valid <= 1'b0;
            ex_mem_valid <= 1'b0;
            mem_wb_valid <= 1'b0;
        end else begin
            if (halt_in_ex) begin
                $display("Execution Halted.");
                hlt <= 1'b1;
            end

            if (mem_control_flush) begin
                pc <= mem_read_data;
            end else if (ex_control_flush) begin
                pc <= branch_target;
            end else if (!hazard_stall && !halt_in_ex) begin
                pc <= pc + 64'd4;
            end

            if (mem_control_flush || ex_control_flush || halt_in_ex) begin
                if_id_valid <= 1'b0;
                if_id_pc <= 64'b0;
                if_id_instr <= 32'b0;
            end else if (!hazard_stall) begin
                if_id_valid <= 1'b1;
                if_id_pc <= pc;
                if_id_instr <= {memory.bytes[pc+3], memory.bytes[pc+2], memory.bytes[pc+1], memory.bytes[pc]};
            end

            if (mem_control_flush || ex_control_flush || hazard_stall || halt_in_ex) begin
                id_ex_valid <= 1'b0;
                ex_pc <= 64'b0;
                ex_opcode <= 5'b0;
                ex_rd <= 5'b0;
                ex_rs <= 5'b0;
                ex_rt <= 5'b0;
                ex_imm <= 12'b0;
                ex_use_immediate <= 1'b0;
                ex_use_fpu_instruction <= 1'b0;
                ex_is_branch <= 1'b0;
                A <= 64'b0;
                B <= 64'b0;
                RD_LATCH <= 64'b0;
            end else begin
                id_ex_valid <= if_id_valid;
                ex_pc <= if_id_pc;
                ex_opcode <= opcode;
                ex_rd <= rd;
                ex_rs <= rs;
                ex_rt <= rt;
                ex_imm <= imm;
                ex_use_immediate <= use_immediate;
                ex_use_fpu_instruction <= use_fpu_instruction;
                ex_is_branch <= is_branch;
                A <= rs_val;
                B <= rt_val;
                RD_LATCH <= rd_val;
            end

            if (mem_control_flush || halt_in_ex) begin
                ex_mem_valid <= 1'b0;
                mem_pc <= 64'b0;
                mem_opcode <= 5'b0;
                mem_rd <= 5'b0;
                mem_store_data <= 64'b0;
                ALUOut <= 64'b0;
                FPUOut <= 64'b0;
            end else if (id_ex_valid) begin
                if (ex_is_branch && ex_opcode != OP_CALL && ex_opcode != OP_RET) begin
                    ex_mem_valid <= 1'b0;
                    mem_pc <= 64'b0;
                    mem_opcode <= 5'b0;
                    mem_rd <= 5'b0;
                    mem_store_data <= 64'b0;
                    ALUOut <= 64'b0;
                    FPUOut <= 64'b0;
                end else begin
                    ex_mem_valid <= 1'b1;
                    mem_pc <= ex_pc;
                    mem_opcode <= ex_opcode;
                    mem_rd <= ex_rd;
                    mem_store_data <= A;
                    ALUOut <= alu_res;
                    FPUOut <= fpu_res;
                end
            end else begin
                ex_mem_valid <= 1'b0;
                mem_pc <= 64'b0;
                mem_opcode <= 5'b0;
                mem_rd <= 5'b0;
                mem_store_data <= 64'b0;
                ALUOut <= 64'b0;
                FPUOut <= 64'b0;
            end

            if (ex_mem_valid && writes_register(mem_opcode)) begin
                mem_wb_valid <= 1'b1;
                wb_opcode <= mem_opcode;
                wb_rd <= mem_rd;
                wb_alu_out <= ALUOut;
                wb_fpu_out <= FPUOut;
                MDR <= mem_read_data;
            end else begin
                mem_wb_valid <= 1'b0;
                wb_opcode <= 5'b0;
                wb_rd <= 5'b0;
                wb_alu_out <= 64'b0;
                wb_fpu_out <= 64'b0;
                MDR <= mem_read_data;
            end
        end
    end
endmodule
