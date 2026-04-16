`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_phase3;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));
    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests  = 0;
    integer timeout;

    localparam OP_ADDI   = 5'h19;
    localparam OP_BRR_L  = 5'h0A;
    localparam OP_BRNZ   = 5'h0B;
    localparam OP_SHFTLI = 5'h07;
    localparam OP_SHFTRI = 5'h05;
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

    integer cycles;
    always @(posedge clk) if (!reset && !uut.hlt) cycles = cycles + 1;

    initial begin
        // $dumpfile("tinker_phase3.vcd");
        $dumpvars(0, tb_phase3);

        clk   = 0;
        reset = 1;
        cycles = 0;

        // ---- Program ----
        
        // TEST 1: Forward BRR_L (should NOT be predicted in ID -> 2 cycle penalty)
        // [0x2000] ADDI r1, 0, 0, 10
        write_inst(64'h2000, OP_ADDI,  1, 0, 0, 12'd10);
        // [0x2004] BRR_L forward +16 (to 0x2014)
        write_inst(64'h2004, OP_BRR_L, 0, 0, 0, 12'd16);
        // [0x2008] ADDI r1, 0, 0, 99 (skipped)
        write_inst(64'h2008, OP_ADDI,  1, 0, 0, 12'd99);
        // [0x200C] ADDI r1, 0, 0, 88 (skipped)
        write_inst(64'h200C, OP_ADDI,  1, 0, 0, 12'd88);
        // [0x2010] ADDI r1, 0, 0, 77 (skipped)
        write_inst(64'h2010, OP_ADDI,  1, 0, 0, 12'd77);
        
        // [0x2014] ADDI r2, 0, 0, 20
        write_inst(64'h2014, OP_ADDI,  2, 0, 0, 12'd20); 
        
        // TEST 2: Backward BRR_L (should be predicted in ID -> 1 cycle penalty)
        // [0x2018] BRR_L forward +8 (to 0x2020)
        write_inst(64'h2018, OP_BRR_L, 0, 0, 0, 12'd8);
        // [0x201C] PRIV 0 (HALT) -- this is the target of the backward jump
        write_inst(64'h201C, OP_PRIV,  0, 0, 0, 12'd0);
        
        // [0x2020] ADDI r3, 0, 0, 30
        write_inst(64'h2020, OP_ADDI,  3, 0, 0, 12'd30);
        // [0x2024] BRR_L backward -8 (to 0x201C - HALT)
        // offset = -8 is 0xFF8 (12-bit)
        write_inst(64'h2024, OP_BRR_L, 0, 0, 0, 12'hFF8); 

        // ---- Run ----
        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout >= 500) begin
            $display("\n[FATAL] Timeout waiting for HALT.\n");
            $finish;
        end

        $display("\n=== PHASE 3: STATIC BRANCH PREDICTION TESTS ===\n");
        
        assert_reg(1, 64'd10, "Target 1: r1 preserved (forward jump worked)");
        assert_reg(2, 64'd20, "Target 2: reached through forward jump");
        assert_reg(3, 64'd30, "Target 3: reached through second forward jump");
        
        $display("Total cycles: %0d", cycles);
        
        if (passed_tests == total_tests)
            $display("ALL %0d PHASE 3 CORRECTNESS TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PHASE 3 TESTS.", (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
