`timescale 1ns / 1ps
`include "./tinker.sv"

module tb_tinker_2;
    reg clk;
    reg reset;

    tinker_core uut (.clk(clk), .reset(reset));

    always #5 clk = ~clk;

    integer passed_tests = 0;
    integer total_tests = 0;
    integer timeout;

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

    initial begin
        $dumpfile("tinker_pipeline_smoke.vcd");
        $dumpvars(0, tb_tinker_2);

        clk = 0;
        reset = 1;
        write_inst(16'h2000, 5'h19, 5'd1, 5'd0, 5'd0, 12'd5);  // addi r1, 5
        write_inst(16'h2004, 5'h19, 5'd2, 5'd0, 5'd0, 12'd7);  // addi r2, 7
        write_inst(16'h2008, 5'h18, 5'd3, 5'd1, 5'd2, 12'd0);  // add  r3, r1, r2
        write_inst(16'h200C, 5'h0F, 5'd0, 5'd0, 5'd0, 12'd0);  // halt

        #15 reset = 0;

        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        assert_true(uut.if_id_valid && uut.id_ex1_valid, "Independent instructions occupy multiple stages");

        timeout = 0;
        while (!uut.hlt && timeout < 200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        // Let the final older instruction retire through WB after HALT is seen in EX.
        @(posedge clk);

        assert_true(timeout < 200, "Smoke program reaches HALT");
        assert_true(uut.reg_file.registers[3] === 64'd12, "Dependent ADD still produces the correct result");

        if (passed_tests == total_tests)
            $display("ALL %0d PIPELINE SMOKE TESTS PASSED!", total_tests);
        else
            $display("FAILED %0d / %0d PIPELINE SMOKE TESTS.", (total_tests - passed_tests), total_tests);

        $finish;
    end
endmodule
