`timescale 1ns/1ps
`include "tinker.sv"

module tb_phase7;
    reg clk;
    reg reset;
    wire hlt;

    integer cycles;
    integer passed_tests;
    integer total_tests;
    integer i;
    integer addr;
    reg saw_temp_dest;
    reg saw_r1_multi_phys;
    reg saw_r12_multi_phys;
    reg saw_temp_reuse;
    reg [5:0] last_r1_phys;
    reg [5:0] last_r12_phys;
    reg [63:0] seen_temp_phys;

    localparam [63:0] FP_1P5 = 64'h3FF8000000000000;
    localparam [63:0] FP_2P0 = 64'h4000000000000000;
    localparam [63:0] FP_0P5 = 64'h3FE0000000000000;

    tinker_core uut (
        .clk(clk),
        .reset(reset),
        .hlt(hlt)
    );

    task write_inst;
        input [15:0] inst_addr;
        input [4:0] op;
        input [4:0] rd;
        input [4:0] rs;
        input [4:0] rt;
        input [11:0] imm;
        reg [31:0] inst;
        begin
            inst = {op, rd, rs, rt, imm};
            uut.memory.bytes[inst_addr]   = inst[7:0];
            uut.memory.bytes[inst_addr+1] = inst[15:8];
            uut.memory.bytes[inst_addr+2] = inst[23:16];
            uut.memory.bytes[inst_addr+3] = inst[31:24];
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

    always @(posedge clk) begin
        if (!reset) begin
            if (uut.id_ex1_valid && (uut.ex1_phys_rd >= 6'd32)) begin
                saw_temp_dest <= 1'b1;

                if (uut.ex1_rd == 5'd1) begin
                    if ((last_r1_phys != 6'b0) && (last_r1_phys != uut.ex1_phys_rd))
                        saw_r1_multi_phys <= 1'b1;
                    last_r1_phys <= uut.ex1_phys_rd;
                end

                if (uut.ex1_rd == 5'd12) begin
                    if ((last_r12_phys != 6'b0) && (last_r12_phys != uut.ex1_phys_rd))
                        saw_r12_multi_phys <= 1'b1;
                    last_r12_phys <= uut.ex1_phys_rd;
                end

                if (uut.ex1_rd == 5'd14) begin
                    if (seen_temp_phys[uut.ex1_phys_rd])
                        saw_temp_reuse <= 1'b1;
                    seen_temp_phys[uut.ex1_phys_rd] <= 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 0;
        reset = 1;
        cycles = 0;
        passed_tests = 0;
        total_tests = 0;
        saw_temp_dest = 0;
        saw_r1_multi_phys = 0;
        saw_r12_multi_phys = 0;
        saw_temp_reuse = 0;
        last_r1_phys = 0;
        last_r12_phys = 0;
        seen_temp_phys = 64'b0;

        for (i = 0; i < 4096; i = i + 1)
            uut.memory.bytes[i] = 8'h0;

        addr = 16'h2000;
        write_inst(addr, 5'h19,  1, 0, 0, 12'd5);  addr = addr + 4;   // r1 = 5
        write_inst(addr, 5'h19,  2, 0, 0, 12'd7);  addr = addr + 4;   // r2 = 7
        write_inst(addr, 5'h19,  1, 0, 0, 12'd9);  addr = addr + 4;   // r1 = 9
        write_inst(addr, 5'h19,  1, 0, 0, 12'd11); addr = addr + 4;   // r1 = 11
        write_inst(addr, 5'h18,  3, 1, 2, 12'd0);  addr = addr + 4;   // r3 = 18
        write_inst(addr, 5'h18,  4, 2, 2, 12'd0);  addr = addr + 4;   // r4 = 14
        write_inst(addr, 5'h19,  5, 0, 0, 12'd1);  addr = addr + 4;   // r5 = 1
        write_inst(addr, 5'h19,  5, 0, 0, 12'd2);  addr = addr + 4;   // r5 = 2
        write_inst(addr, 5'h18,  6, 5, 2, 12'd0);  addr = addr + 4;   // r6 = 9
        write_inst(addr, 5'h0A,  0, 0, 0, 12'd12); addr = addr + 4;   // branch to 0x2030
        write_inst(addr, 5'h19,  7, 0, 0, 12'd99); addr = addr + 4;   // flushed
        write_inst(addr, 5'h19,  8, 0, 0, 12'd55); addr = addr + 4;   // flushed
        write_inst(addr, 5'h19,  7, 0, 0, 12'd42); addr = addr + 4;   // r7 = 42
        write_inst(addr, 5'h19,  8, 0, 0, 12'd1);  addr = addr + 4;   // r8 = 1
        write_inst(addr, 5'h14, 12, 20, 21, 12'd0);addr = addr + 4;   // r12 = 3.5
        write_inst(addr, 5'h15, 12, 21, 20, 12'd0);addr = addr + 4;   // r12 = 0.5
        write_inst(addr, 5'h14, 13, 12, 20, 12'd0);addr = addr + 4;   // r13 = 2.0

        for (i = 1; i <= 36; i = i + 1) begin
            write_inst(addr, 5'h19, 14, 0, 0, i[11:0]);
            addr = addr + 4;
        end

        write_inst(addr, 5'h18, 15, 14, 2, 12'd0); addr = addr + 4;   // r15 = 36 + 7 = 43
        write_inst(addr, 5'h0F,  0, 0, 0, 12'd0);

        #20 reset = 0;
        uut.reg_file.registers[20] = FP_1P5;
        uut.reg_file.registers[21] = FP_2P0;

        while (!hlt && cycles < 600) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        @(posedge clk);

        $display("\n=== PHASE 7: REGISTER RENAMING TESTS ===");
        $display("[RESULT] r3  = %0d", uut.reg_file.registers[3]);
        $display("[RESULT] r4  = %0d", uut.reg_file.registers[4]);
        $display("[RESULT] r6  = %0d", uut.reg_file.registers[6]);
        $display("[RESULT] r7  = %0d", uut.reg_file.registers[7]);
        $display("[RESULT] r8  = %0d", uut.reg_file.registers[8]);
        $display("[RESULT] r12 = %h", uut.reg_file.registers[12]);
        $display("[RESULT] r13 = %h", uut.reg_file.registers[13]);
        $display("[RESULT] r14 = %0d", uut.reg_file.registers[14]);
        $display("[RESULT] r15 = %0d", uut.reg_file.registers[15]);
        $display("[RESULT] cycles = %0d", cycles);

        assert_true(hlt, "Rename test program reaches HALT");
        assert_true(uut.reg_file.registers[3] == 64'd32, "Latest renamed r1 value feeds integer add");
        assert_true(uut.reg_file.registers[4] == 64'd14, "Independent integer result remains correct");
        assert_true(uut.reg_file.registers[6] == 64'd10, "Second renamed destination commits correctly");
        assert_true(uut.reg_file.registers[7] == 64'd42, "Flushed wrong-path integer write does not leak");
        assert_true(uut.reg_file.registers[8] == 64'd1, "Post-branch correct-path write retires");
        assert_true(uut.reg_file.registers[12] == FP_0P5, "Repeated FP writes to one logical register commit newest value");
        assert_true(uut.reg_file.registers[13] == FP_2P0, "Dependent FP op reads renamed producer result");
        assert_true(uut.reg_file.registers[14] == 64'd666, "Rename pressure loop commits final overwrite");
        assert_true(uut.reg_file.registers[15] == 64'd673, "Consumer after rename-pressure loop sees latest value");
        assert_true(saw_temp_dest, "At least one destination used a temporary physical register");
        assert_true(saw_r1_multi_phys, "Repeated integer writes allocated multiple physical registers");
        assert_true(saw_r12_multi_phys, "Repeated FP writes allocated multiple physical registers");
        assert_true(saw_temp_reuse, "Freed temporary physical registers were reused");
        assert_true(cycles < 250, "Rename test finishes without runaway stalls");

        if (passed_tests == total_tests)
            $display("ALL %0d PHASE 7 TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PHASE 7 TESTS.", (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
