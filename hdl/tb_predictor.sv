`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_predictor;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));
    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests  = 0;
    integer timeout;

    localparam OP_ADDI   = 5'h19;
    localparam OP_SUBI   = 5'h1B;
    localparam OP_BRNZ   = 5'h0B;
    localparam OP_PRIV   = 5'h0F;
    localparam OP_BRR_L  = 5'h0A;
    localparam OP_SHFTLI = 5'h07;

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

    integer cycles;
    always @(posedge clk) if (!reset && !uut.hlt) cycles = cycles + 1;

    initial begin
        $dumpfile("tinker_predictor.vcd");
        $dumpvars(0, tb_predictor);

        clk   = 0;
        reset = 1;
        cycles = 0;

        // ---- Program Setup ----
        // 0x2000: r1 = 4 (loop counter)
        write_inst(64'h2000, OP_ADDI,  1, 0, 0, 12'd4);
        
        // 0x2004: Build target register r3 = 0x2014 (loop start)
        write_inst(64'h2004, OP_ADDI,  3, 0, 0, 12'h201);
        write_inst(64'h2008, OP_SHFTLI, 3, 0, 0, 12'd4);
        write_inst(64'h200C, OP_ADDI,  3, 0, 0, 12'h004); // r3 = 0x2014
        
        // 0x2010: Jump to loop body
        write_inst(64'h2010, OP_BRR_L, 0, 0, 0, 12'd4); // to 0x2014
        
        // 0x2014: loop_start:
        // 0x2014: r2 = r2 + 1
        write_inst(64'h2014, OP_ADDI,  2, 0, 0, 12'd1);
        // 0x2018: r1 = r1 - 1
        write_inst(64'h2018, OP_SUBI,  1, 0, 0, 12'd1);
        // 0x201C: if r1 != 0 jump 0x2014 (r3)
        write_inst(64'h201C, OP_BRNZ,  3, 1, 0, 12'd0);
        
        // 0x2020: Halt
        write_inst(64'h2020, OP_PRIV,  0, 0, 0, 12'd0);

        // ---- Run ----
        #15 reset = 0;

        timeout = 0;
        while (!uut.hlt && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        $display("\n=== PHASE 3.5: DYNAMIC PREDICTOR TESTS ===\n");
        
        if (uut.reg_file.registers[2] === 64'd4) begin
            $display("[PASS] Loop executed 4 times (r2 = 4)");
        end else begin
            $display("[FAIL] Loop count mismatch (r2 = %0d, expected 4)", uut.reg_file.registers[2]);
        end

        $display("Total cycles: %0d", cycles);
        
        if (cycles < 70) begin
            $display("[PASS] Performance check passed (%0d cycles)", cycles);
        end else begin
            $display("[FAIL] Performance check failed (%0d cycles)", cycles);
        end

        $finish;
    end
endmodule
