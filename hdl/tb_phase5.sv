`timescale 1ns/1ps
`include "tinker.sv"

module tb_phase5;
    reg clk;
    reg reset;
    wire hlt;

    tinker_core uut (
        .clk(clk),
        .reset(reset),
        .hlt(hlt)
    );

    localparam [63:0] FP_4P0  = 64'h4010000000000000;
    localparam [63:0] FP_2P0  = 64'h4000000000000000;
    localparam [63:0] FP_6P0  = 64'h4018000000000000;
    localparam [63:0] FP_3P0  = 64'h4008000000000000;
    localparam [63:0] FP_8P0  = 64'h4020000000000000;
    localparam [63:0] FP_20P0 = 64'h4034000000000000;
    localparam [63:0] FP_5P0  = 64'h4014000000000000;
    localparam [63:0] FP_4_OVER_3 = 64'h3FF5555555555555;

    // Instruction sequence
    initial begin
        for (integer i=0; i<4096; i=i+1) uut.memory.bytes[i] = 8'h0;

        // [0x2000] MUL r3, r1, r2 (r3 = 50, Latency 4)
        write_inst(16'h2000, 5'h1C, 3, 1, 2, 12'd0); 
        // [0x2004] ADD r4, r1, r2 (r4 = 15, Latency 1)
        write_inst(16'h2004, 5'h18, 4, 1, 2, 12'd0);
        // [0x2008] DIV r5, r1, r2 (r5 = 2, Latency 8)
        write_inst(16'h2008, 5'h1D, 5, 1, 2, 12'd0);
        // [0x200C] ADDF r12, r10, r11 (r12 = 6.0)
        write_inst(16'h200C, 5'h14, 12, 10, 11, 12'd0);
        // [0x2010] SUBF r13, r10, r11 (r13 = 2.0)
        write_inst(16'h2010, 5'h15, 13, 10, 11, 12'd0);
        // [0x2014] MULF r14, r10, r11 (r14 = 8.0)
        write_inst(16'h2014, 5'h16, 14, 10, 11, 12'd0);
        // [0x2018] DIVF r15, r16, r17 (r15 = 5.0)
        write_inst(16'h2018, 5'h17, 15, 16, 17, 12'd0);
        // [0x201C] DIVF r18, r19, r20 (r18 = 4.0 / 3.0, rounding-sensitive)
        write_inst(16'h201C, 5'h17, 18, 19, 20, 12'd0);
        // [0x2020] PRIV 0 (HALT)
        write_inst(16'h2020, 5'h0F, 0, 0, 0, 12'd0);
    end

    task write_inst;
        input [15:0] addr;
        input [4:0] op;
        input [4:0] rd;
        input [4:0] rs;
        input [4:0] rt;
        input [11:0] imm;
        begin
            uut.memory.bytes[addr]   = {rt[0], imm[6:0]};
            uut.memory.bytes[addr+1] = {imm[11:7], rt[4:1]};
            uut.memory.bytes[addr+2] = {rd[1:0], rs[4:0], imm[11:11]}; // Note: simple packing
            // Using the packing from instruction_decoder.sv:
            // opcode = instr[31:27]
            // rd = instr[26:22]
            // rs = instr[21:17]
            // rt = instr[16:12]
            // imm = instr[11:0]
            {uut.memory.bytes[addr+3], uut.memory.bytes[addr+2], uut.memory.bytes[addr+1], uut.memory.bytes[addr]} = {op, rd, rs, rt, imm};
        end
    endtask

    always #5 clk = ~clk;

    integer cycles = 0;
    integer fpu_busy_cycles = 0;
    reg saw_fpu_s1 = 0;
    reg saw_fpu_s2 = 0;
    reg saw_fpu_s3 = 0;
    reg saw_fpu_s4 = 0;
    reg saw_fpu_s5 = 0;
    initial begin
        clk = 0;
        reset = 1;
        #20 reset = 0;

        // Load architectural state after reset releases so the register file
        // does not immediately clear the test inputs back to zero.
        uut.reg_file.registers[1] = 64'd10;
        uut.reg_file.registers[2] = 64'd5;
        uut.reg_file.registers[10] = FP_4P0;
        uut.reg_file.registers[11] = FP_2P0;
        uut.reg_file.registers[16] = FP_20P0;
        uut.reg_file.registers[17] = FP_4P0;
        uut.reg_file.registers[19] = FP_4P0;
        uut.reg_file.registers[20] = FP_3P0;

        while (!hlt && cycles < 200) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (uut.fpu.s1_valid) saw_fpu_s1 = 1;
            if (uut.fpu.s2_valid) saw_fpu_s2 = 1;
            if (uut.fpu.s3_valid) saw_fpu_s3 = 1;
            if (uut.fpu.s4_valid) saw_fpu_s4 = 1;
            if (uut.fpu.s5_valid) saw_fpu_s5 = 1;
            if (uut.fpu_busy) fpu_busy_cycles = fpu_busy_cycles + 1;
            if (uut.alu_busy_stall) $display("Cycle %d: Stall due to ALU/FPU Busy", cycles);
        end

        $display("\n=== PHASE 5: DEEP PIPELINE TESTS ===");
        $display("[RESULT] r3 (10 * 5) = %d (expected 50)", uut.reg_file.registers[3]);
        $display("[RESULT] r4 (10 + 5) = %d (expected 15)", uut.reg_file.registers[4]);
        $display("[RESULT] r5 (10 / 5) = %d (expected 2)", uut.reg_file.registers[5]);
        $display("[RESULT] r12 (4.0 + 2.0) = %h (expected %h)", uut.reg_file.registers[12], FP_6P0);
        $display("[RESULT] r13 (4.0 - 2.0) = %h (expected %h)", uut.reg_file.registers[13], FP_2P0);
        $display("[RESULT] r14 (4.0 * 2.0) = %h (expected %h)", uut.reg_file.registers[14], FP_8P0);
        $display("[RESULT] r15 (20.0 / 4.0) = %h (expected %h)", uut.reg_file.registers[15], FP_5P0);
        $display("[RESULT] r18 (4.0 / 3.0) = %h (expected %h)", uut.reg_file.registers[18], FP_4_OVER_3);
        $display("[RESULT] FPU busy cycles observed = %0d", fpu_busy_cycles);
        $display("[RESULT] FPU stages seen = %0d%0d%0d%0d%0d", saw_fpu_s1, saw_fpu_s2, saw_fpu_s3, saw_fpu_s4, saw_fpu_s5);
        $display("Total cycles: %d", cycles);
        
        if (uut.reg_file.registers[3] == 64'd50 &&
            uut.reg_file.registers[4] == 64'd15 &&
            uut.reg_file.registers[5] == 64'd2 &&
            uut.reg_file.registers[12] == FP_6P0 &&
            uut.reg_file.registers[13] == FP_2P0 &&
            uut.reg_file.registers[14] == FP_8P0 &&
            uut.reg_file.registers[15] == FP_5P0 &&
            uut.reg_file.registers[18] == FP_4_OVER_3 &&
            saw_fpu_s1 && saw_fpu_s2 && saw_fpu_s3 && saw_fpu_s4 && saw_fpu_s5 &&
            cycles > 20 &&
            cycles < 200) begin
            $display("[PASS] Long-latency operations verified.");
        end else begin
            $display("[FAIL] Results or cycle count mismatch.");
        end
        $finish;
    end
endmodule
