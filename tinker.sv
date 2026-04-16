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
    integer i;
    reg halt_pending;

    reg if_id_valid;
    reg [63:0] if_id_pc;
    reg [31:0] if_id_instr;

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

    reg ex2_mem_valid;
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
    wire [4:0] reg_write_rd;

    register_file reg_file (
        .clk(clk),
        .reset(reset),
        .data(reg_write_data),
        .rd(rd),
        .rs(rs),
        .rt(rt),
        .write_rd(reg_write_rd),
        .write_enable(reg_write_en),
        .rd_val(rd_val),
        .rs_val(rs_val),
        .rt_val(rt_val),
        .r31_val(r31_val)
    );

    // Forward-declared so forwarding muxes can reference it before the memory instantiation
    wire [63:0] mem_read_data;

    // --- Phase 3.5: Dynamic Branch Predictor State ---
    reg [1:0]  bht       [0:63]; // 2-bit saturating counters
    reg [63:0] btb_tgt   [0:63]; // Branch Target Buffer
    reg [51:0] btb_tag   [0:63]; // BTB tags (using bits 63:12)
    reg [63:0] btb_valid;        // Valid bit for each BTB entry

    // --- Phase 4: Store Buffer State ---
    reg [63:0] sb_addr  [0:3];
    reg [63:0] sb_data  [0:3];
    reg [3:0]  sb_valid;
    reg [1:0]  sb_head;
    reg [1:0]  sb_tail;
    reg [2:0]  sb_count;

    // --- Architecture Constants & Wire Helpers ---
    wire [63:0] stack_addr = r31_val - 64'd8;

    // --- ALU / FPU Calculations (EX2 Stage) ---
    wire [63:0] alu_input_a = uses_rd_as_alu_a(ex2_opcode) ? ex2_RD_LATCH : ex2_A;
    wire [63:0] alu_input_b = ex2_use_immediate ? extend_imm(ex2_opcode, ex2_imm) : ex2_B;
    wire [63:0] alu_res;
    wire [63:0] fpu_res;
    wire alu_busy, alu_done;
    wire fpu_busy, fpu_done;

    wire alu_start = ex1_ex2_valid && !ex2_use_fpu_instruction && (ex2_opcode == OP_MUL || ex2_opcode == OP_DIV);
    wire fpu_start = ex1_ex2_valid && ex2_use_fpu_instruction && (ex2_opcode == OP_MULF || ex2_opcode == OP_DIVF);

    ALU alu_inst (
        .clk(clk),
        .reset(reset),
        .start(alu_start && !ex2_long_op_started),
        .a(alu_input_a),
        .b(alu_input_b),
        .op(ex2_opcode),
        .res(alu_res),
        .busy(alu_busy),
        .done(alu_done)
    );

    FPU fpu_inst (
        .clk(clk),
        .reset(reset),
        .start(fpu_start && !ex2_long_op_started),
        .a(ex2_A),
        .b(alu_input_b),
        .op(ex2_opcode),
        .res(fpu_res),
        .busy(fpu_busy),
        .done(fpu_done)
    );

    // --- Store-to-Load Forwarding (SLF) Logic ---
    wire phys_addr_is_stack = (mem_opcode == OP_CALL || mem_opcode == OP_RET);
    wire [63:0] mem_addr = phys_addr_is_stack ? stack_addr : ALUOut;

    // SLF logic to find newest matching SB entry
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
    
    // --- Phase 5: Forwarding Network ---
    // Priority (highest → lowest): EX2, MEM, WB
    // ---------------------------------------------------------------

    // Forwarded result from EX2 stage
    wire [63:0] fwd_val_ex2 = (ex2_opcode >= OP_ADDF && ex2_opcode <= OP_DIVF) ? fpu_res : alu_res;

    // Forwarded result from MEM stage
    wire [63:0] fwd_val_ex2_mem = (mem_opcode == OP_MOV_ML) ? forwarded_mem_read_data : (mem_opcode >= OP_ADDF && mem_opcode <= OP_DIVF) ? FPUOut : ALUOut;

    // Forwarded result from WB stage
    wire [63:0] fwd_val_mem_wb = (wb_opcode == OP_MOV_ML) ? MDR : (wb_opcode >= OP_ADDF && wb_opcode <= OP_DIVF) ? wb_fpu_out : wb_alu_out;

    // --- forwarded_A (rs operand) ---
    wire fwd_A_ex2   = id_ex1_valid && ex1_ex2_valid && writes_register(ex2_opcode) && (ex2_opcode != OP_MOV_ML) && uses_rs(ex1_opcode) && (ex1_rs == ex2_rd);
    wire fwd_A_mem   = id_ex1_valid && ex2_mem_valid && writes_register(mem_opcode) && uses_rs(ex1_opcode) && (ex1_rs == mem_rd);
    wire fwd_A_wb    = id_ex1_valid && mem_wb_valid && writes_register(wb_opcode) && uses_rs(ex1_opcode) && (ex1_rs == wb_rd);

    wire [63:0] forwarded_A =
        fwd_A_ex2     ? fwd_val_ex2     :
        fwd_A_mem     ? fwd_val_ex2_mem :
        fwd_A_wb      ? fwd_val_mem_wb  :
                        A;

    // --- forwarded_B (rt operand) ---
    wire fwd_B_ex2   = id_ex1_valid && ex1_ex2_valid && writes_register(ex2_opcode) && (ex2_opcode != OP_MOV_ML) && uses_rt(ex1_opcode) && (ex1_rt == ex2_rd);
    wire fwd_B_mem   = id_ex1_valid && ex2_mem_valid && writes_register(mem_opcode) && uses_rt(ex1_opcode) && (ex1_rt == mem_rd);
    wire fwd_B_wb    = id_ex1_valid && mem_wb_valid && writes_register(wb_opcode) && uses_rt(ex1_opcode) && (ex1_rt == wb_rd);

    wire [63:0] forwarded_B =
        fwd_B_ex2     ? fwd_val_ex2     :
        fwd_B_mem     ? fwd_val_ex2_mem :
        fwd_B_wb      ? fwd_val_mem_wb  :
                        B;

    // --- forwarded_RD (rd used as source) ---
    wire fwd_RD_ex2  = id_ex1_valid && ex1_ex2_valid && writes_register(ex2_opcode) && (ex2_opcode != OP_MOV_ML) && uses_rd_source(ex1_opcode) && (ex1_rd == ex2_rd);
    wire fwd_RD_mem  = id_ex1_valid && ex2_mem_valid && writes_register(mem_opcode) && uses_rd_source(ex1_opcode) && (ex1_rd == mem_rd);
    wire fwd_RD_wb   = id_ex1_valid && mem_wb_valid && writes_register(wb_opcode) && uses_rd_source(ex1_opcode) && (ex1_rd == wb_rd);

    wire [63:0] forwarded_RD =
        fwd_RD_ex2    ? fwd_val_ex2     :
        fwd_RD_mem    ? fwd_val_ex2_mem :
        fwd_RD_wb     ? fwd_val_mem_wb  :
                        RD_LATCH;

    // --- Physical Memory Interface ---
    assign reg_write_data = (mem_opcode == OP_MOV_ML) ? forwarded_mem_read_data :
                            (mem_opcode >= OP_ADDF && mem_opcode <= OP_DIVF) ? FPUOut :
                            ALUOut;

    reg take_branch;
    reg [63:0] branch_target;

    // Predicted next PC
    wire [5:0] pred_idx = pc[7:2];
    wire [51:0] curr_tag = pc[63:12];
    wire btb_hit = btb_valid[pred_idx] && (btb_tag[pred_idx] == curr_tag);
    wire predict_takenRaw = btb_hit && (bht[pred_idx] >= 2'b10);
    wire [63:0] predicted_target = btb_tgt[pred_idx];
    wire [63:0] next_pc_predict = predict_takenRaw ? predicted_target : (pc + 64'd4);

    reg if_id_predicted_taken;
    reg [63:0] if_id_predicted_target;

    // --- Final Data Logic (Memory Interface) ---
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
    assign reg_write_rd = mem_rd;

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

    // --- Hazard Detection (6-stage) ---
    // Load-use: An instruction in EX1 needs a result from a Load currently in EX2.
    // The Load result won't be ready until it reaches the MEM stage.
    wire lu_rs = id_ex1_valid && uses_rs(ex1_opcode)        && ex1_ex2_valid && (ex2_opcode == OP_MOV_ML) && (ex1_rs == ex2_rd);
    wire lu_rt = id_ex1_valid && uses_rt(ex1_opcode)        && ex1_ex2_valid && (ex2_opcode == OP_MOV_ML) && (ex1_rt == ex2_rd);
    wire lu_rd = id_ex1_valid && uses_rd_source(ex1_opcode) && ex1_ex2_valid && (ex2_opcode == OP_MOV_ML) && (ex1_rd == ex2_rd);
    wire lu_stall = lu_rs || lu_rt || lu_rd;

    wire sb_full = (sb_count == 3'd4);
    wire sb_stall = ex2_mem_valid && mem_write && sb_full;
    wire alu_busy_stall = alu_busy || fpu_busy;

    wire pipeline_stall = lu_rs || lu_rt || lu_rd || sb_stall || alu_busy_stall;
    wire halt_in_ex2 = ex1_ex2_valid && (ex2_opcode == OP_PRIV) && (ex2_imm == 12'b0);

    // Dynamic resolution in EX2
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

            // Reset predictor tables
            btb_valid <= 64'b0;
            for (i = 0; i < 64; i = i + 1) begin
                bht[i] <= 2'b01; // Initialize to Weakly Not Taken
                btb_tgt[i] <= 64'b0;
                btb_tag[i] <= 52'b0;
            end

            ex2_mem_valid <= 1'b0;
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

            // Reset Store Buffer
            sb_head <= 2'b0;
            sb_tail <= 2'b0;
            sb_count <= 3'b0;
            sb_valid <= 4'b0;
            for (i=0; i<4; i=i+1) begin
                sb_addr[i] <= 64'b0;
                sb_data[i] <= 64'b0;
            end
        end else if (hlt) begin
            if_id_valid <= 1'b0;
            id_ex1_valid <= 1'b0;
            ex1_ex2_valid <= 1'b0;
            ex2_mem_valid <= 1'b0;
            mem_wb_valid <= 1'b0;
        end else begin
            if (halt_in_ex2) begin
                halt_pending <= 1'b1;
            end

            if (halt_pending && (sb_count == 3'b0) && !(ex2_mem_valid && mem_write)) begin
                $display("Execution Halted.");
                hlt <= 1'b1;
            end

            if (mem_control_flush) begin
                pc <= mem_read_data;
            end else if (ex_control_flush) begin
                pc <= take_branch ? branch_target : (ex2_pc + 64'd4);
            end else if (!pipeline_stall && !halt_in_ex2 && !halt_pending) begin
                pc <= next_pc_predict;
            end

            // --- STAGE 0: Fetch -> IF/ID ---
            if (mem_control_flush || ex_control_flush || halt_in_ex2 || halt_pending) begin
                if_id_valid <= 1'b0;
                if_id_pc <= 64'b0;
                if_id_instr <= 32'b0;
                if_id_predicted_taken <= 1'b0;
                if_id_predicted_target <= 64'b0;
            end else if (!pipeline_stall) begin
                if_id_valid <= 1'b1;
                if_id_pc <= pc;
                if_id_instr <= {memory.bytes[pc+3], memory.bytes[pc+2], memory.bytes[pc+1], memory.bytes[pc]};
                if_id_predicted_taken <= predict_takenRaw;
                if_id_predicted_target <= predicted_target;
            end

            // --- STAGE 1: IF/ID -> ID/EX1 ---
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
                A <= 64'b0;
                B <= 64'b0;
                RD_LATCH <= 64'b0;
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
                A <= rs_val;
                B <= rt_val;
                RD_LATCH <= rd_val;
            end

            // --- STAGE 2: ID/EX1 -> EX1/EX2 ---
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
            end else if (alu_busy_stall) begin
                // FREEZE EX2 during own functional unit busy state
            end else if (sb_stall || lu_stall) begin
                // BUBBLE EX2 if preceding stages are stalled
                ex1_ex2_valid <= 1'b0;
                ex2_long_op_started <= 1'b0;
            end else begin
                ex1_ex2_valid <= id_ex1_valid;
                ex2_pc <= ex1_pc;
                ex2_opcode <= ex1_opcode;
                ex2_rd <= ex1_rd;
                ex2_A <= forwarded_A;
                ex2_B <= forwarded_B;
                ex2_RD_LATCH <= forwarded_RD;
                ex2_imm <= ex1_imm;
                ex2_use_immediate <= ex1_use_immediate;
                ex2_use_fpu_instruction <= ex1_use_fpu_instruction;
                ex2_is_branch <= ex1_is_branch;
                ex2_predicted_taken <= ex1_predicted_taken;
                ex2_predicted_target <= ex1_predicted_target;
                ex2_long_op_started <= 1'b0;
            end

            // Keep long_op_started high once pulse is sent
            if (ex1_ex2_valid && !pipeline_stall) begin
                if (alu_start || fpu_start)
                    ex2_long_op_started <= 1'b1;
            end

            // --- STAGE 3: EX1/EX2 -> EX2/MEM ---
            if (mem_control_flush || halt_in_ex2) begin
                ex2_mem_valid <= 1'b0;
                mem_pc <= 64'b0;
                mem_opcode <= 5'b0;
                mem_rd <= 5'b0;
                mem_store_data <= 64'b0;
                ALUOut <= 64'b0;
                FPUOut <= 64'b0;
            end else begin
                // A branch in EX2 (that is not CALL/RET handled in MEM/EX2) 
                // essentially bubbles the next stage until the penalty is over.
                if (ex1_ex2_valid && ex2_is_branch && ex2_opcode != OP_CALL && ex2_opcode != OP_RET) begin
                    ex2_mem_valid <= 1'b0;
                    mem_pc <= 64'b0;
                    mem_opcode <= 5'b0;
                    mem_rd <= 5'b0;
                    mem_store_data <= 64'b0;
                    ALUOut <= 64'b0;
                    FPUOut <= 64'b0;
                end else if (sb_stall || alu_busy_stall) begin
                    // Freeze MEM stages during stalls
                end else begin
                    ex2_mem_valid <= ex1_ex2_valid;
                    mem_pc <= ex2_pc;
                    mem_opcode <= ex2_opcode;
                    mem_rd <= ex2_rd;
                    mem_store_data <= ex2_A;
                    ALUOut <= alu_res;
                    FPUOut <= fpu_res;
                end
            end

            // --- STAGE 4: EX2/MEM -> MEM/WB ---
            if (halt_in_ex2 || halt_pending) begin
                mem_wb_valid <= 1'b0;
                wb_opcode <= 5'b0;
                wb_rd <= 5'b0;
                wb_alu_out <= 64'b0;
                wb_fpu_out <= 64'b0;
                MDR <= 64'b0;
            end else begin
                mem_wb_valid <= ex2_mem_valid && writes_register(mem_opcode);
                wb_opcode <= mem_opcode;
                wb_rd <= mem_rd;
                wb_alu_out <= ALUOut;
                wb_fpu_out <= FPUOut;
                MDR <= forwarded_mem_read_data;
            end

            // Predictor Training (Update BHT and BTB)
            if (ex1_ex2_valid && ex2_is_branch && ex2_opcode != OP_RET) begin
                // Update BHT counter
                if (take_branch) begin
                    if (bht[ex2_pc[7:2]] != 2'b11) bht[ex2_pc[7:2]] <= bht[ex2_pc[7:2]] + 2'b01;
                end else begin
                    if (bht[ex2_pc[7:2]] != 2'b00) bht[ex2_pc[7:2]] <= bht[ex2_pc[7:2]] - 2'b01;
                end
                
                // Update BTB entry if taken
                if (take_branch) begin
                    btb_tgt[ex2_pc[7:2]] <= branch_target;
                    btb_tag[ex2_pc[7:2]] <= ex2_pc[63:12];
                    btb_valid[ex2_pc[7:2]] <= 1'b1;
                end
            end

            // Store Buffer Allocation and Retirement
            // Retirement (Oldest first)
            if (sb_retire_ready) begin
                sb_valid[sb_head] <= 1'b0;
                sb_head <= sb_head + 2'b1;
                if (!(ex2_mem_valid && mem_write && !sb_full)) begin
                    sb_count <= sb_count - 3'b1;
                end
            end

            // Allocation (Newest)
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
endmodule
