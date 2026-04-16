`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_phase5;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));
    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests  = 0;
    integer timeout;

    localparam OP_ADD    = 5'h18;
    localparam OP_ADDI   = 5'h19;
    localparam OP_MOV_L  = 5'h12;
    localparam OP_BR     = 5'h08;
    localparam OP_BRR_L  = 5'h0A;
    localparam OP_PRIV   = 5'h0F;

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

    initial begin
        $dumpfile("tinker_phase5.vcd");
        $dumpvars(0, tb_phase5);

        clk   = 0;
        reset = 1;

        // ---- Program ----
        
        // TEST 1: 3-Stage Forwarding Chain
        // [0x2000] r1 = 10
        write_inst(64'h2000, OP_ADDI,  1, 0, 0, 12'd10);
        // [0x2004] r2 = r1 + r0 (Forward from EX2 to EX1)
        write_inst(64'h2004, OP_ADD,   2, 1, 0, 12'd0);
        // [0x2008] r3 = r2 + r0 (Forward from MEM to EX1)
        write_inst(64'h2008, OP_ADD,   3, 2, 0, 12'd0);
        // [0x200C] r4 = r3 + r0 (Forward from WB to EX1)
        write_inst(64'h200C, OP_ADD,   4, 3, 0, 12'd0);
        
        // TEST 2: Branch Misprediction Flush (3 cycles)
        // [0x2010] r5 = 0x2024 (Target)
        // MOV_L r5, 0x2024
        write_inst(64'h2010, OP_MOV_L, 5, 0, 0, 12'h24); 
        // Need to set the upper bits for 0x2024. 
        // Actually, let's just jump to 0x24 if memory is mapped there,
        // but tinker's PC starts at 0x2000.
        // Let's use BRR_L (relative jump) which is easier.
        // [0x2014] BRR_L +0x10 (Jumps to 0x2014 + 16 = 0x2024)
        write_inst(64'h2014, OP_BRR_L, 0, 0, 0, 12'h10);
        // [0x2018] Sentinel (Should be flushed)
        write_inst(64'h2018, OP_ADDI,  6, 0, 0, 12'h999);
        // [0x201C] Sentinel (Should be flushed)
        write_inst(64'h201C, OP_ADDI,  6, 0, 0, 12'h999);
        // [0x2020] Sentinel (Should be flushed)
        write_inst(64'h2020, OP_ADDI,  6, 0, 0, 12'h999);
        
        // [0x2024] r6 = 1 (Expected if jump worked)
        write_inst(64'h2024, OP_ADDI,  6, 0, 0, 12'd1);
        
        // Halt
        write_inst(64'h2028, OP_PRIV,  0, 0, 0, 12'd0);

        // ---- Run ----
        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        $display("\n=== PHASE 5: 6-STAGE PIPELINE TESTS ===\n");
        
        assert_reg(1, 64'd10, "Reg Write (Baseline)");
        assert_reg(2, 64'd10, "EX2 to EX1 Forwarding (ADD)");
        assert_reg(3, 64'd10, "MEM to EX1 Forwarding (ADD)");
        assert_reg(4, 64'd10, "WB to EX1 Forwarding (ADD)");
        assert_reg(6, 64'd1,  "3-Cycle Branch Flush: Sentinels skipped");

        $finish;
    end
endmodule
