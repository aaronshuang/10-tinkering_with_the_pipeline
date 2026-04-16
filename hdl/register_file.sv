// Unified Register File for Tomasulo OOO
// Handles Physical Register Storage (temp_registers) and Architectural State (registers)
// CDB writes directly to physical registers.
// Commit stage writes to architectural registers.

`timescale 1ns/1ps
module register_file (
    input clk,
    input reset,

    // ── CDB WRITE PORT (Physical state) ─────────────────────────────────────
    input        cdb_valid,
    input  [5:0] cdb_tag,
    input [63:0] cdb_data,

    // ── COMMIT PORTS (Architectural state) ───────────────────────────────────
    input        commit_en0,
    input  [4:0] commit_ard0,
    input [63:0] commit_data0,
    input        commit_en1,
    input  [4:0] commit_ard1,
    input [63:0] commit_data1,

    // ── DISPATCH READ PORTS (for up to 2 instrs) ─────────────────────────────
    input  [5:0] rs0, rt0, rd0,
    input  [5:0] rs1, rt1, rd1,
    output [63:0] rs0_val, rt0_val, rd0_val,
    output [63:0] rs1_val, rt1_val, rd1_val,
    output [63:0] r31_val
);
    reg [63:0] registers [0:31];      // Architectural
    reg [63:0] temp_registers [0:31]; // Physical (32..63)

    // ── Read and Bypass Logic ───────────────────────────────────────────────
    function [63:0] get_val;
        input [5:0] tag;
        begin
            if (tag < 6'd32) 
                get_val = registers[tag[4:0]];
            else
                get_val = temp_registers[tag[4:0]];
        end
    endfunction

    // Combinatorial bypass from CDB
    assign rs0_val = (cdb_valid && cdb_tag == rs0) ? cdb_data : get_val(rs0);
    assign rt0_val = (cdb_valid && cdb_tag == rt0) ? cdb_data : get_val(rt0);
    assign rd0_val = (cdb_valid && cdb_tag == rd0) ? cdb_data : get_val(rd0);
    
    assign rs1_val = (cdb_valid && cdb_tag == rs1) ? cdb_data : get_val(rs1);
    assign rt1_val = (cdb_valid && cdb_tag == rt1) ? cdb_data : get_val(rt1);
    assign rd1_val = (cdb_valid && cdb_tag == rd1) ? cdb_data : get_val(rd1);

    assign r31_val = (cdb_valid && cdb_tag == 6'd63) ? cdb_data : registers[31]; // R31 is often special

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 31; i = i + 1) registers[i] <= 64'b0;
            registers[31] <= 64'd524288; // Default stack pointer
            for (i = 0; i < 32; i = i + 1) temp_registers[i] <= 64'b0;
        end else begin
            // ── Write Results (to physical registers) ───────────────────────
            if (cdb_valid && cdb_tag >= 6'd32) begin
                temp_registers[cdb_tag[4:0]] <= cdb_data;
            end else if (cdb_valid) begin
                registers[cdb_tag[4:0]] <= cdb_data; // Should not usually happen in Renaming OOO
            end

            // ── Commit Results (to architectural registers) ──────────────────
            if (commit_en0) begin
                registers[commit_ard0] <= commit_data0;
            end
            if (commit_en1) begin
                registers[commit_ard1] <= commit_data1;
            end
        end
    end
endmodule
