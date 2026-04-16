`timescale 1ns/1ps
`include "tinker.sv"

module tb_phase6;
    reg clk;
    reg reset;
    wire hlt;

    integer cycles;
    integer passed_tests;
    integer total_tests;
    reg saw_dual_fetch;
    reg saw_dual_issue;
    reg saw_serial_mem;

    localparam [63:0] FP_1P5 = 64'h3FF8000000000000;
    localparam [63:0] FP_2P0 = 64'h4000000000000000;
    localparam [63:0] FP_3P5 = 64'h400C000000000000;
    localparam [63:0] FP_0P5 = 64'h3FE0000000000000;

    tinker_core uut (
        .clk(clk),
        .reset(reset),
        .hlt(hlt)
    );

    task write_inst;
        input [15:0] addr;
        input [4:0] op;
        input [4:0] rd;
        input [4:0] rs;
        input [4:0] rt;
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
        input [15:0] addr;
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

    task assert_true;
        input condition;
        input [255:0] name;
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                passed_tests = passed_tests + 1;
                $display("[PASS] %s", name);
            end else begin
                $display("[FAIL] %s", name);
            end
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        cycles = 0;
        passed_tests = 0;
        total_tests = 0;
        saw_dual_fetch = 0;
        saw_dual_issue = 0;
        saw_serial_mem = 0;

        write_mem64(16'h0100, 64'd99);

        write_inst(16'h2000, 5'h19,  1, 0, 0, 12'd10);   // addi r1, 10
        write_inst(16'h2004, 5'h19,  2, 0, 0, 12'd20);   // addi r2, 20
        write_inst(16'h2008, 5'h19,  3, 0, 0, 12'd1);    // addi r3, 1
        write_inst(16'h200C, 5'h19,  4, 0, 0, 12'd2);    // addi r4, 2
        write_inst(16'h2010, 5'h18,  5, 1, 2, 12'd0);    // add  r5, r1, r2
        write_inst(16'h2014, 5'h1A,  6, 2, 1, 12'd0);    // sub  r6, r2, r1
        write_inst(16'h2018, 5'h10,  7, 0, 0, 12'h100);  // mov_ml r7, [0x100]
        write_inst(16'h201C, 5'h19,  8, 0, 0, 12'd5);    // addi r8, 5
        write_inst(16'h2020, 5'h14, 10, 20, 21, 12'd0);  // addf r10, r20, r21
        write_inst(16'h2024, 5'h15, 11, 21, 20, 12'd0);  // subf r11, r21, r20
        write_inst(16'h2028, 5'h0F,  0, 0, 0, 12'd0);    // halt

        #20 reset = 0;
        uut.reg_file.registers[20] = FP_1P5;
        uut.reg_file.registers[21] = FP_2P0;

        while (!hlt && cycles < 200) begin
            @(posedge clk);
            cycles = cycles + 1;

            if (uut.if_id_valid && uut.if_id_valid1)
                saw_dual_fetch = 1'b1;
            if (uut.id_ex1_valid && uut.id_ex1_valid1)
                saw_dual_issue = 1'b1;
            if (uut.if_id_valid && (uut.if_id_pc == 64'h2018) && !uut.if_id_valid1)
                saw_serial_mem = 1'b1;
        end

        @(posedge clk);

        $display("\n=== PHASE 6: DUAL-ISSUE TESTS ===");
        $display("[RESULT] r5  = %0d", uut.reg_file.registers[5]);
        $display("[RESULT] r6  = %0d", uut.reg_file.registers[6]);
        $display("[RESULT] r7  = %0d", uut.reg_file.registers[7]);
        $display("[RESULT] r8  = %0d", uut.reg_file.registers[8]);
        $display("[RESULT] r10 = %h", uut.reg_file.registers[10]);
        $display("[RESULT] r11 = %h", uut.reg_file.registers[11]);
        $display("[RESULT] cycles = %0d", cycles);

        assert_true(cycles < 40, "Dual-issue run finishes in fewer cycles than a serialized baseline");
        assert_true(saw_dual_fetch, "Front-end fetches a two-instruction packet");
        assert_true(saw_dual_issue, "Issue stage carries two independent instructions together");
        assert_true(saw_serial_mem, "A memory instruction prevents an unsafe same-cycle pair");
        assert_true(uut.reg_file.registers[5] == 64'd30, "Integer lane 0 result is correct");
        assert_true(uut.reg_file.registers[6] == 64'd10, "Integer lane 1 result is correct");
        assert_true(uut.reg_file.registers[7] == 64'd99, "Load on lane 0 preserves correctness");
        assert_true(uut.reg_file.registers[8] == 64'd5, "Instruction after serialized load still executes");
        assert_true(uut.reg_file.registers[10] == FP_3P5, "Paired ADDF result is correct");
        assert_true(uut.reg_file.registers[11] == FP_0P5, "Paired SUBF result is correct");

        if (passed_tests == total_tests)
            $display("ALL %0d PHASE 6 TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PHASE 6 TESTS.", (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
