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

    // Instruction sequence
    initial begin
        for (integer i=0; i<4096; i=i+1) uut.memory.bytes[i] = 8'h0;

        // [0x2000] MUL r3, r1, r2 (r3 = 50, Latency 4)
        write_inst(16'h2000, 5'h1C, 3, 1, 2, 12'd0); 
        // [0x2004] ADD r4, r1, r2 (r4 = 15, Latency 1)
        write_inst(16'h2004, 5'h18, 4, 1, 2, 12'd0);
        // [0x2008] DIV r5, r1, r2 (r5 = 2, Latency 8)
        write_inst(16'h2008, 5'h1D, 5, 1, 2, 12'd0);
        // [0x200C] MULF r12, r10, r11 (r12 = 50.0, Latency 4)
        write_inst(16'h200C, 5'h16, 12, 10, 11, 12'd0);
        // [0x2010] PRIV 0 (HALT)
        write_inst(16'h2010, 5'h0F, 0, 0, 0, 12'd0);
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
    initial begin
        // $dumpfile("tinker_phase5.vcd");
        $dumpvars(0, tb_phase5);
        clk = 0;
        reset = 1;
        #20 reset = 0;

        // Load architectural state after reset releases so the register file
        // does not immediately clear the test inputs back to zero.
        uut.reg_file.registers[1] = 64'd10;
        uut.reg_file.registers[2] = 64'd5;
        uut.reg_file.registers[10] = 64'h4024000000000000;
        uut.reg_file.registers[11] = 64'h4014000000000000;

        while (!hlt && cycles < 100) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (uut.alu_busy_stall) $display("Cycle %d: Stall due to ALU/FPU Busy", cycles);
        end

        $display("\n=== PHASE 5: DEEP PIPELINE TESTS ===");
        $display("[RESULT] r3 (10 * 5) = %d (expected 50)", uut.reg_file.registers[3]);
        $display("[RESULT] r4 (10 + 5) = %d (expected 15)", uut.reg_file.registers[4]);
        $display("[RESULT] r5 (10 / 5) = %d (expected 2)", uut.reg_file.registers[5]);
        $display("[RESULT] r12 (10.0 * 5.0) = %h (expected 4049000000000000)", uut.reg_file.registers[12]);
        $display("Total cycles: %d", cycles);
        
        if (uut.reg_file.registers[3] == 50 && uut.reg_file.registers[5] == 2 && cycles > 20) begin
            $display("[PASS] Long-latency operations verified.");
        end else begin
            $display("[FAIL] Results or cycle count mismatch.");
        end
        $finish;
    end
endmodule
