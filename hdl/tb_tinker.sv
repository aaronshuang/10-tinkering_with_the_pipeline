`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_tinker;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));

    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests = 0;
    integer timeout;

    reg saw_overlap;
    reg saw_three_stage_overlap;
    reg saw_hazard_stall;
    reg saw_ex_flush;
    reg saw_mem_flush;

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
        input [4:0] reg_idx;
        input [63:0] expected;
        input [255:0] test_name;
        begin
            total_tests = total_tests + 1;
            if (uut.reg_file.registers[reg_idx] === expected) begin
                $display("[PASS] %s (r%0d = %h)", test_name, reg_idx, expected);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %s (r%0d = %h, Expected %h)", test_name, reg_idx, uut.reg_file.registers[reg_idx], expected);
            end
        end
    endtask

    task assert_mem64;
        input [63:0] addr;
        input [63:0] expected;
        input [255:0] test_name;
        reg [63:0] actual;
        begin
            actual = {
                uut.memory.bytes[addr+7], uut.memory.bytes[addr+6],
                uut.memory.bytes[addr+5], uut.memory.bytes[addr+4],
                uut.memory.bytes[addr+3], uut.memory.bytes[addr+2],
                uut.memory.bytes[addr+1], uut.memory.bytes[addr]
            };
            total_tests = total_tests + 1;
            if (actual === expected) begin
                $display("[PASS] %s (%h)", test_name, expected);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %s (%h, Expected %h)", test_name, actual, expected);
            end
        end
    endtask

    task assert_true;
        input condition;
        input [255:0] test_name;
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                $display("[PASS] %s", test_name);
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] %s", test_name);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!reset && !uut.hlt) begin
            if (uut.if_id_valid && uut.id_ex1_valid)
                saw_overlap <= 1'b1;

            if (uut.if_id_valid && uut.id_ex1_valid && uut.ex1_ex2_valid && uut.ex2_mem_valid)
                saw_three_stage_overlap <= 1'b1;

            if (uut.pipeline_stall)
                saw_hazard_stall <= 1'b1;

            if (uut.ex_control_flush)
                saw_ex_flush <= 1'b1;

            if (uut.mem_control_flush)
                saw_mem_flush <= 1'b1;
        end
    end

    initial begin
        clk = 0;
        reset = 1;

        saw_overlap = 0;
        saw_three_stage_overlap = 0;
        saw_hazard_stall = 0;
        saw_ex_flush = 0;
        saw_mem_flush = 0;

        write_mem64(16'h0108, 64'h3FF8000000000000); // 1.5
        write_mem64(16'h0110, 64'h4000000000000000); // 2.0
        write_mem64(16'h0118, 64'h7FF8000000000000); // NaN

        write_inst(16'h2000, OP_ADDI,   1,  0,  0, 12'h005);
        write_inst(16'h2004, OP_ADDI,   2,  0,  0, 12'h00A);
        write_inst(16'h2008, OP_ADD,    3,  1,  2, 12'h000);
        write_inst(16'h200C, OP_SUB,    4,  2,  1, 12'h000);
        write_inst(16'h2010, OP_MUL,    5,  1,  2, 12'h000);
        write_inst(16'h2014, OP_DIV,    6,  2,  1, 12'h000);
        write_inst(16'h2018, OP_AND,    7,  1,  2, 12'h000);
        write_inst(16'h201C, OP_OR,     8,  1,  2, 12'h000);
        write_inst(16'h2020, OP_XOR,    9,  1,  2, 12'h000);
        write_inst(16'h2024, OP_NOT,   10,  1,  0, 12'h000);
        write_inst(16'h2028, OP_ADDI,  11,  0,  0, 12'h002);
        write_inst(16'h202C, OP_SHFTL, 12,  1, 11, 12'h000);
        write_inst(16'h2030, OP_SHFTR, 13,  2, 11, 12'h000);
        write_inst(16'h2034, OP_SHFTLI, 1,  0,  0, 12'h002);
        write_inst(16'h2038, OP_SHFTRI, 2,  0,  0, 12'h001);
        write_inst(16'h203C, OP_MOV_L, 14,  0,  0, 12'hABC);
        write_inst(16'h2040, OP_MOV_RR,15,  1,  0, 12'h000);
        write_inst(16'h2044, OP_MOV_SM, 0, 15,  0, 12'h100);
        write_inst(16'h2048, OP_MOV_ML,16,  0,  0, 12'h100);
        write_inst(16'h204C, OP_BRR_L,  0,  0,  0, 12'h008);
        write_inst(16'h2050, OP_ADDI,  17,  0,  0, 12'h999);
        write_inst(16'h2054, OP_ADDI,  22,  0,  0, 12'h20E);
        write_inst(16'h2058, OP_SHFTLI,22,  0,  0, 12'h004);
        write_inst(16'h205C, OP_ADDI,  22,  0,  0, 12'h000);
        write_inst(16'h2060, OP_CALL,  22,  0,  0, 12'h000);
        write_inst(16'h2064, OP_MOV_ML,23,  0,  0, 12'h108);
        write_inst(16'h2068, OP_MOV_ML,24,  0,  0, 12'h110);
        write_inst(16'h206C, OP_ADDF,  25, 23, 24, 12'h000);
        write_inst(16'h2070, OP_SUBF,  26, 24, 23, 12'h000);
        write_inst(16'h2074, OP_MULF,  27, 23, 24, 12'h000);
        write_inst(16'h2078, OP_DIVF,  28, 24,  0, 12'h000);
        write_inst(16'h207C, OP_MOV_ML,29,  0,  0, 12'h118);
        write_inst(16'h2080, OP_MULF,  30, 29, 24, 12'h000);
        write_inst(16'h2084, OP_ADDI,  18,  0,  0, 12'h209);
        write_inst(16'h2088, OP_SHFTLI,18,  0,  0, 12'h004);
        write_inst(16'h208C, OP_ADDI,  18,  0,  0, 12'h008);
        write_inst(16'h2090, OP_BRGT,  18,  1,  2, 12'h000);
        write_inst(16'h2094, OP_ADDI,  17,  0,  0, 12'h123);
        write_inst(16'h2098, OP_ADDI,  19,  0,  0, 12'h20A);
        write_inst(16'h209C, OP_SHFTLI,19,  0,  0, 12'h004);
        write_inst(16'h20A0, OP_ADDI,  19,  0,  0, 12'h00C);
        write_inst(16'h20A4, OP_BRNZ,  19,  1,  0, 12'h000);
        write_inst(16'h20A8, OP_ADDI,  17,  0,  0, 12'h456);
        write_inst(16'h20AC, OP_ADDI,  20,  0,  0, 12'h20C);
        write_inst(16'h20B0, OP_SHFTLI,20,  0,  0, 12'h004);
        write_inst(16'h20B4, OP_ADDI,  20,  0,  0, 12'h004);
        write_inst(16'h20B8, OP_BR,    20,  0,  0, 12'h000);
        write_inst(16'h20BC, OP_ADDI,  17,  0,  0, 12'h789);
        write_inst(16'h20C0, OP_ADDI,  17,  0,  0, 12'h790);
        write_inst(16'h20C4, OP_MOV_RR,22,  0,  0, 12'h000);
        write_inst(16'h20C8, OP_ADDI,  22,  0,  0, 12'h008);
        write_inst(16'h20CC, OP_BRR_R, 22,  0,  0, 12'h000);
        write_inst(16'h20D0, OP_ADDI,  17,  0,  0, 12'hAAA);
        write_inst(16'h20D4, OP_PRIV,   0,  0,  0, 12'h000);

        write_inst(16'h20E0, OP_ADDI,  21,  0,  0, 12'h111);
        write_inst(16'h20E4, OP_RET,    0,  0,  0, 12'h000);

        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        @(posedge clk);

        if (timeout >= 2000) begin
            $display("\n[FATAL] Timeout waiting for HALT.\n");
            $finish;
        end

        $display("TINKER PIPELINE TEST RESULTS");

        assert_reg(1,  64'h14, "SHFTLI keeps ADDI result and shifts r1");
        assert_reg(2,  64'h05, "SHFTRI keeps ADDI result and shifts r2");
        assert_reg(3,  64'h0F, "ADD result is preserved");
        assert_reg(4,  64'h05, "SUB result is preserved");
        assert_reg(5,  64'h32, "MUL result is preserved");
        assert_reg(6,  64'h02, "DIV result is preserved");
        assert_reg(7,  64'h00, "AND result is preserved");
        assert_reg(8,  64'h0F, "OR result is preserved");
        assert_reg(9,  64'h0F, "XOR result is preserved");
        assert_reg(10, 64'hFFFFFFFFFFFFFFFA, "NOT result is preserved");
        assert_reg(11, 64'h02, "Shift amount register is preserved");
        assert_reg(12, 64'h14, "Register-based left shift works");
        assert_reg(13, 64'h02, "Register-based right shift works");
        assert_reg(14, 64'h0000000000000ABC, "MOV_L preserves upper bits and inserts immediate");
        assert_reg(15, 64'h14, "MOV_RR copies the pipelined source value");
        assert_reg(16, 64'h14, "MOV_ML loads stored data");
        assert_reg(17, 64'h00, "Taken branches skip all sentinel writes");
        assert_reg(21, 64'h111, "CALL/RET reaches the function body");
        assert_reg(25, 64'h400C000000000000, "ADDF result is correct");
        assert_reg(26, 64'h3FE0000000000000, "SUBF result is correct");
        assert_reg(27, 64'h4008000000000000, "MULF result is correct");
        assert_reg(28, 64'h7FF0000000000000, "DIVF by zero returns infinity");
        assert_reg(30, 64'h7FF8000000000000, "NaN propagates through MULF");

        assert_mem64(16'h0100, 64'h14, "Store path writes the expected 64-bit value");
        assert_mem64(64'd524280, 64'h0000000000002064, "CALL writes the return address to the stack slot");

        assert_true(saw_overlap, "Pipeline overlaps fetch and execute work");
        assert_true(saw_three_stage_overlap, "Pipeline reaches at least three active stages");
        assert_true(saw_hazard_stall, "Hazard detection inserts a stall for RAW dependencies");
        assert_true(saw_ex_flush, "Taken branch or call flushes younger instructions");
        assert_true(saw_mem_flush, "RET flushes younger instructions from MEM");

        if (passed_tests == total_tests)
            $display("ALL %0d PIPELINE TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PIPELINE TESTS.", (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
