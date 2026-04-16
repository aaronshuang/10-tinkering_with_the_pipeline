`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_phase4;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));
    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests  = 0;
    integer timeout;

    localparam OP_ADDI   = 5'h19;
    localparam OP_MOV_SM = 5'h13;
    localparam OP_MOV_ML = 5'h10;
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
        $dumpfile("tinker_phase4.vcd");
        $dumpvars(0, tb_phase4);

        clk   = 0;
        reset = 1;

        // ---- Program ----
        
        // TEST 1: Basic SLF
        // [0x2000] r1 = 0x100 (addr)
        write_inst(64'h2000, OP_ADDI,  1, 0, 0, 12'h100);
        // [0x2004] r2 = 0xAAA (data)
        write_inst(64'h2004, OP_ADDI,  2, 0, 0, 12'hAAA);
        // [0x2008] STORE [r1], r2 (Pending in SB)
        write_inst(64'h2008, OP_MOV_SM, 1, 2, 0, 12'd0);
        // [0x200C] LOAD r4, [r1]  (Should forward from SB)
        write_inst(64'h200C, OP_MOV_ML, 4, 1, 0, 12'd0);
        
        // TEST 2: Multi-Store SLF (Newest entry wins)
        // [0x2010] r5 = 0xBBB
        write_inst(64'h2010, OP_ADDI,  5, 0, 0, 12'hBBB);
        // [0x2014] STORE [r1], r5 (Pending in SB, newer than 0xAAA)
        write_inst(64'h2014, OP_MOV_SM, 1, 5, 0, 12'd0);
        // [0x2018] LOAD r6, [r1]  (Should get 0xBBB)
        write_inst(64'h2018, OP_MOV_ML, 6, 1, 0, 12'd0);

        // TEST 3: Buffer Full Stall
        // SB has 4 slots.
        // We already have 2 pending stores to 0x100.
        // Let's add 2 more stores to reach capacity.
        write_inst(64'h201C, OP_MOV_SM, 1, 5, 0, 12'd0); // 3rd store
        write_inst(64'h2020, OP_MOV_SM, 1, 5, 0, 12'd0); // 4th store (SB now full)
        
        // Next store should stall until at least one retires.
        // A store takes 1 cycle to retire when bus is idle.
        write_inst(64'h2024, OP_ADDI, 10, 0, 0, 12'd42); // This will proceed after SB slot opens
        
        // Halt
        write_inst(64'h2028, OP_PRIV,  0, 0, 0, 12'd0);

        // ---- Run ----
        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        $display("\n=== PHASE 4: MEMORY QUEUE TESTS ===\n");
        
        assert_reg(4, 64'hAAA, "Basic SLF: Load got data from single pending store");
        assert_reg(6, 64'hBBB, "Multi-Store SLF: Load got newest data from multiple pending stores");
        assert_reg(10, 64'd42, "SB Full Stall: Instructions proceeded after buffer drained");

        $finish;
    end
endmodule
