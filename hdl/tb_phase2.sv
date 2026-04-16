`timescale 1ns / 1ps
`include "./tinker.sv"

// ---------------------------------------------------------------------------
// Phase 2 testbench – forwarding and hazard detection
//
// Program layout (all at 0x2000):
//
//  [0x2000] ADDI  r1,  0, 0,  5      r1  = 5
//  [0x2004] ADD   r2,  r1, r1        r2  = 10   (EX/MEM fwd: r1→A and r1→B)
//  [0x2008] ADD   r3,  r2, r1        r3  = 15   (EX/MEM fwd r2→A, MEM/WB fwd r1→B)
//  [0x200C] SUB   r4,  r3, r2        r4  = 5    (EX/MEM fwd r3→A, MEM/WB fwd r2→B)
//
//  [0x2010] ADDI  r5,  0, 0, 10      r5  = 10
//  [0x2014] ADDI  r5,  0, 0,  5      r5  = 15   (EX/MEM fwd r5 via forwarded_RD)
//  [0x2018] ADDI  r5,  0, 0,  3      r5  = 18   (EX/MEM fwd r5 via forwarded_RD)
//
//  [0x201C] MOV_ML r6, r0, 0, 0x050  r6  = mem[0x050] = 42 (pre-stored)
//  [0x2020] ADD   r7,  r6, r6        r7  = 84   (load-use 1-stall + WB fwd r6→A,B)
//  [0x2024] ADD   r8,  r7, r6        r8  = 126  (EX/MEM fwd r7→A, MEM/WB fwd r6→B)
//
//  [0x2028] ADDI  r9,  0, 0, 33      r9  = 33
//  [0x202C] MOV_SM r0, r9, 0, 0x100  mem[0x100] = 33 (EX/MEM fwd r9→forwarded_A)
//  [0x2030] MOV_ML r10, r0,0, 0x100  r10 = 33
//
//  -- BRNZ target r11 = 0x204C --
//  [0x2034] ADDI  r11, 0, 0, 0x204   r11 = 0x204
//  [0x2038] SHFTLI r11,0, 0, 4       r11 = 0x2040 (EX/MEM fwd r11 via RD)
//  [0x203C] ADDI  r11, 0, 0, 12      r11 = 0x204C (EX/MEM fwd r11 via RD)
//
//  [0x2040] ADDI  r12, 0, 0, 7       r12 = 7  (non-zero condition)
//  [0x2044] BRNZ  r11, r12           jump to r11(0x204C) if r12!=0
//                                     r12: EX/MEM fwd (condition), r11: MEM/WB fwd (target)
//  [0x2048] ADDI  r13, 0, 0, 0x999   FAIL sentinel (should be skipped)
//  [0x204C] ADDI  r13, 0, 0, 1       r13 = 1 (PASS – branch taken)
//
//  -- BRGT target r14 = 0x206C --
//  [0x2050] ADDI  r14, 0, 0, 0x206   r14 = 0x206
//  [0x2054] SHFTLI r14,0, 0, 4       r14 = 0x2060 (EX/MEM fwd r14 via RD)
//  [0x2058] ADDI  r14, 0, 0, 12      r14 = 0x206C (EX/MEM fwd r14 via RD)
//
//  [0x205C] ADDI  r16, 0, 0, 10      r16 = 10 (rs for BRGT; MEM/WB fwd at BRGT time)
//  [0x2060] ADDI  r15, 0, 0, 3       r15 = 3  (rt for BRGT; EX/MEM fwd at BRGT time)
//  [0x2064] BRGT  r14, r16, r15      jump to r14(0x206C) if r16>r15 (10>3 signed, true)
//                                     r16: MEM/WB fwd (rs), r15: EX/MEM fwd (rt)
//  [0x2068] ADDI  r17, 0, 0, 0x999   FAIL sentinel (should be skipped)
//  [0x206C] ADDI  r17, 0, 0, 2       r17 = 2 (PASS – branch taken)
//  [0x2070] PRIV  0,  0, 0, 0        HALT
// ---------------------------------------------------------------------------

module tb_phase2;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));
    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests  = 0;
    integer timeout;

    reg saw_hazard_stall;
    reg saw_ex_flush;

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

    task write_inst;
        input [63:0] addr;
        input [4:0]  op;
        input [4:0]  rd;
        input [4:0]  rs;
        input [4:0]  rt;
        input [11:0] imm;
        reg [31:0] inst;
        begin
            inst = {op, rd, rs, rt, imm};
            uut.memory.bytes[addr]   = inst[7:0];
            uut.memory.bytes[addr+1] = inst[15:8];
            uut.memory.bytes[addr+2] = inst[23:16];
            uut.memory.bytes[addr+3] = inst[31:24];
        end
    endtask

    task write_mem64;
        input [63:0] addr;
        input [63:0] data;
        begin
            uut.memory.bytes[addr]   = data[7:0];
            uut.memory.bytes[addr+1] = data[15:8];
            uut.memory.bytes[addr+2] = data[23:16];
            uut.memory.bytes[addr+3] = data[31:24];
            uut.memory.bytes[addr+4] = data[39:32];
            uut.memory.bytes[addr+5] = data[47:40];
            uut.memory.bytes[addr+6] = data[55:48];
            uut.memory.bytes[addr+7] = data[63:56];
        end
    endtask

    task assert_reg;
        input [4:0]   reg_idx;
        input [63:0]  expected;
        input [511:0] test_name;
        begin
            total_tests = total_tests + 1;
            if (uut.reg_file.registers[reg_idx] === expected) begin
                $display("[PASS] %0s  (r%0d = 0x%0h)", test_name, reg_idx, expected);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %0s  (r%0d = 0x%0h, expected 0x%0h)",
                         test_name, reg_idx,
                         uut.reg_file.registers[reg_idx], expected);
            end
        end
    endtask

    task assert_mem64;
        input [63:0]  addr;
        input [63:0]  expected;
        input [511:0] test_name;
        reg [63:0] actual;
        begin
            actual = {uut.memory.bytes[addr+7], uut.memory.bytes[addr+6],
                      uut.memory.bytes[addr+5], uut.memory.bytes[addr+4],
                      uut.memory.bytes[addr+3], uut.memory.bytes[addr+2],
                      uut.memory.bytes[addr+1], uut.memory.bytes[addr]};
            total_tests = total_tests + 1;
            if (actual === expected) begin
                $display("[PASS] %0s  (mem[0x%0h] = 0x%0h)", test_name, addr, expected);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %0s  (mem[0x%0h] = 0x%0h, expected 0x%0h)",
                         test_name, addr, actual, expected);
            end
        end
    endtask

    task assert_true;
        input        condition;
        input [511:0] test_name;
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                $display("[PASS] %0s", test_name);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %0s", test_name);
            end
        end
    endtask

    // Monitor pipeline hazard / flush signals
    always @(posedge clk) begin
        if (!reset && !uut.hlt) begin
            if (uut.pipeline_stall)
                saw_hazard_stall <= 1'b1;
            if (uut.ex_control_flush) saw_ex_flush     <= 1'b1;
        end
    end

    initial begin
        $dumpfile("tinker_phase2.vcd");
        $dumpvars(0, tb_phase2);

        clk   = 0;
        reset = 1;
        saw_hazard_stall = 0;
        saw_ex_flush     = 0;

        // ---- pre-store data in memory ----
        write_mem64(16'h0050, 64'd42);   // for load-use test  (r6)

        // ---- program ----

        // Segment 1 – back-to-back ALU forwarding
        write_inst(16'h2000, OP_ADDI,  1,  0,  0, 12'h005); // r1  = 5
        write_inst(16'h2004, OP_ADD,   2,  1,  1, 12'h000); // r2  = 10  EX/MEM fwd r1 (A+B)
        write_inst(16'h2008, OP_ADD,   3,  2,  1, 12'h000); // r3  = 15  EX/MEM r2, MEM/WB r1
        write_inst(16'h200C, OP_SUB,   4,  3,  2, 12'h000); // r4  = 5   EX/MEM r3, MEM/WB r2

        // Segment 2 – ADDI accumulate (rd-as-alu-a forwarding chain)
        write_inst(16'h2010, OP_ADDI,  5,  0,  0, 12'h00A); // r5  = 10
        write_inst(16'h2014, OP_ADDI,  5,  0,  0, 12'h005); // r5  = 15  EX/MEM fwd r5 via RD
        write_inst(16'h2018, OP_ADDI,  5,  0,  0, 12'h003); // r5  = 18  EX/MEM fwd r5 via RD

        // Segment 3 – load-use stall + WB forwarding
        write_inst(16'h201C, OP_MOV_ML, 6,  0,  0, 12'h050); // r6  = mem[0x050] = 42
        write_inst(16'h2020, OP_ADD,   7,  6,  6, 12'h000);  // r7  = 84   load-use stall
        write_inst(16'h2024, OP_ADD,   8,  7,  6, 12'h000);  // r8  = 126  EX/MEM r7, MEM/WB r6

        // Segment 4 – store-data forwarding  (forwarded_A → mem_store_data)
        write_inst(16'h2028, OP_ADDI,  9,  0,  0, 12'h021); // r9  = 33
        write_inst(16'h202C, OP_MOV_SM, 0, 9,  0, 12'h100); // mem[0+0x100] = r9 = 33
        write_inst(16'h2030, OP_MOV_ML,10,  0,  0, 12'h100); // r10 = mem[0x100] = 33

        // Build BRNZ target: r11 = 0x204C
        write_inst(16'h2034, OP_ADDI, 11,  0,  0, 12'h204); // r11 = 0x204
        write_inst(16'h2038, OP_SHFTLI,11, 0,  0, 12'h004); // r11 = 0x2040  EX/MEM fwd r11
        write_inst(16'h203C, OP_ADDI, 11,  0,  0, 12'h00C); // r11 = 0x204C  EX/MEM fwd r11

        // Segment 5 – BRNZ with forwarded condition (rs) and forwarded target (rd)
        write_inst(16'h2040, OP_ADDI, 12,  0,  0, 12'h007); // r12 = 7 (condition != 0)
        write_inst(16'h2044, OP_BRNZ, 11, 12,  0, 12'h000); // jump to r11(0x204C) if r12!=0
                                                             // r12: EX/MEM fwd; r11: MEM/WB fwd
        write_inst(16'h2048, OP_ADDI, 13,  0,  0, 12'h999); // FAIL sentinel (must be skipped)
        write_inst(16'h204C, OP_ADDI, 13,  0,  0, 12'h001); // r13 = 1 (PASS – branch taken)

        // Build BRGT target: r14 = 0x206C
        write_inst(16'h2050, OP_ADDI, 14,  0,  0, 12'h206); // r14 = 0x206
        write_inst(16'h2054, OP_SHFTLI,14, 0,  0, 12'h004); // r14 = 0x2060  EX/MEM fwd r14
        write_inst(16'h2058, OP_ADDI, 14,  0,  0, 12'h00C); // r14 = 0x206C  EX/MEM fwd r14

        // Segment 6 – BRGT with forwarded rs and rt (signed comparison)
        write_inst(16'h205C, OP_ADDI, 16,  0,  0, 12'h00A); // r16 = 10  (MEM/WB fwd at BRGT)
        write_inst(16'h2060, OP_ADDI, 15,  0,  0, 12'h003); // r15 = 3   (EX/MEM fwd at BRGT)
        write_inst(16'h2064, OP_BRGT, 14, 16, 15, 12'h000); // jump to r14(0x206C) if r16>r15
                                                             // r14: regfile; r16: MEM/WB; r15: EX/MEM
        write_inst(16'h2068, OP_ADDI, 17,  0,  0, 12'h999); // FAIL sentinel (must be skipped)
        write_inst(16'h206C, OP_ADDI, 17,  0,  0, 12'h002); // r17 = 2 (PASS – branch taken)

        write_inst(16'h2070, OP_PRIV,  0,  0,  0, 12'h000); // HALT

        // ---- run ----
        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 3000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout >= 3000) begin
            $display("\n[FATAL] Timeout waiting for HALT.\n");
            $finish;
        end

        $display("\n=== PHASE 2: FORWARDING & HAZARD DETECTION TESTS ===\n");

        // --- Segment 1: back-to-back ALU forwarding ---
        $display("-- Seg 1: back-to-back ALU forwarding --");
        assert_reg( 1, 64'd5,   "ADDI r1=5 baseline");
        assert_reg( 2, 64'd10,  "ADD r2=r1+r1 (EX/MEM fwd both operands)");
        assert_reg( 3, 64'd15,  "ADD r3=r2+r1 (EX/MEM r2, MEM/WB r1)");
        assert_reg( 4, 64'd5,   "SUB r4=r3-r2 (EX/MEM r3, MEM/WB r2)");

        // --- Segment 2: ADDI accumulate (RD forwarding chain) ---
        $display("-- Seg 2: ADDI accumulate via forwarded_RD --");
        assert_reg( 5, 64'd18,  "ADDI chain r5: 10+5+3=18 (3 consecutive EX/MEM fwd via RD)");

        // --- Segment 3: load-use ---
        $display("-- Seg 3: load-use stall + WB forwarding --");
        assert_reg( 6, 64'd42,  "MOV_ML r6 = mem[0x050] = 42");
        assert_reg( 7, 64'd84,  "ADD r7=r6+r6=84 (load-use 1-stall, WB fwd r6)");
        assert_reg( 8, 64'd126, "ADD r8=r7+r6=126 (EX/MEM r7, MEM/WB r6)");

        // --- Segment 4: store-data forwarding ---
        $display("-- Seg 4: store-data forwarding (forwarded_A) --");
        assert_reg( 9, 64'd33,  "ADDI r9 = 33");
        assert_mem64(64'h100, 64'd33, "MOV_SM stores forwarded r9=33 to mem[0x100]");
        assert_reg(10, 64'd33,  "MOV_ML r10 = mem[0x100] = 33");

        // --- Segment 5: BRNZ condition + target forwarding ---
        $display("-- Seg 5: BRNZ with forwarded condition (EX/MEM) and target (MEM/WB) --");
        assert_reg(11, 64'h204C, "r11 built correctly as BRNZ target 0x204C");
        assert_reg(12, 64'd7,    "r12 = 7 (BRNZ condition register)");
        assert_reg(13, 64'd1,    "BRNZ taken (r13=1, not 0x999 sentinel)");

        // --- Segment 6: BRGT rs/rt forwarding ---
        $display("-- Seg 6: BRGT with MEM/WB rs and EX/MEM rt forwarding --");
        assert_reg(14, 64'h206C, "r14 built correctly as BRGT target 0x206C");
        assert_reg(15, 64'd3,    "r15 = 3 (BRGT rt operand)");
        assert_reg(16, 64'd10,   "r16 = 10 (BRGT rs operand)");
        assert_reg(17, 64'd2,    "BRGT taken (r17=2, not 0x999 sentinel)");

        // --- Pipeline behavior ---
        $display("-- Pipeline behavior --");
        assert_true(saw_hazard_stall, "Load-use hazard stall fired (MOV_ML -> ADD)");
        assert_true(saw_ex_flush,     "EX flush fired on taken branch (BRNZ or BRGT)");

        $display("");
        if (passed_tests == total_tests)
            $display("ALL %0d PHASE 2 TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PHASE 2 TESTS.",
                     (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
