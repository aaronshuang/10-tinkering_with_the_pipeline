`timescale 1ns/1ps
module ALU (
    input clk,
    input reset,
    input start,
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    input [5:0] phys_rd_in,
    input [3:0] rob_tag_in,
    input [63:0] pc_in,
    input accept, // CDB arbiter accepted the result
    output reg [63:0] res,
    output reg [5:0] phys_rd_out,
    output reg [3:0] rob_tag_out,
    output reg [4:0] op_out,
    output reg [63:0] pc_out,
    output busy,
    output reg done, // Valid result waiting
    output ready     // Can accept new instruction
);
    localparam [4:0] OP_MUL = 5'h1C;
    localparam [4:0] OP_DIV = 5'h1D;

    reg [3:0] counter;
    reg busy_reg;
    reg [63:0] a_latched, b_latched;
    reg [4:0] op_latched;
    wire [63:0] next_res;

    assign busy = busy_reg;
    assign ready = !busy_reg && !done;

    function [63:0] calc_res;
        input [4:0] op_f;
        input [63:0] a_f, b_f;
        begin
            case (op_f)
                5'h00: calc_res = a_f & b_f;
                5'h01: calc_res = a_f | b_f;
                5'h02: calc_res = a_f ^ b_f;
                5'h03: calc_res = ~a_f;
                5'h18, 5'h19: calc_res = a_f + b_f;
                5'h10, 5'h13: calc_res = a_f + b_f;
                5'h1a, 5'h1b: calc_res = a_f - b_f;
                5'h1c: calc_res = a_f * b_f;
                5'h1d: calc_res = (b_f != 0) ? (a_f / b_f) : 64'b0;
                5'h04, 5'h05: calc_res = a_f >> b_f[5:0];
                5'h06, 5'h07: calc_res = a_f << b_f[5:0];
                5'h11: calc_res = a_f;
                5'h12: calc_res = {a_f[63:12], b_f[11:0]};
                default: calc_res = 64'b0;
            endcase
        end
    endfunction

    assign next_res = calc_res(busy_reg ? op_latched : op, busy_reg ? a_latched : a, busy_reg ? b_latched : b);

    always @(posedge clk) begin
        if (reset) begin
            counter <= 0; busy_reg <= 0; done <= 0; res <= 0; phys_rd_out <= 0; rob_tag_out <= 0; op_out <= 0; pc_out <= 0;
            a_latched <= 0; b_latched <= 0; op_latched <= 0;
        end else begin
            if (start && ready) begin
                if (op == OP_MUL || op == OP_DIV) begin
                    busy_reg <= 1; done <= 0;
                    counter <= (op == OP_MUL) ? 4'd3 : 4'd7; 
                    a_latched <= a; b_latched <= b; op_latched <= op;
                    phys_rd_out <= phys_rd_in; rob_tag_out <= rob_tag_in; op_out <= op; pc_out <= pc_in;
                end else begin
                    busy_reg <= 0; done <= 1;
                    res <= next_res;
                    phys_rd_out <= phys_rd_in; rob_tag_out <= rob_tag_in; op_out <= op; pc_out <= pc_in;
                end
            end else if (busy_reg) begin
                if (counter == 0) begin
                    busy_reg <= 0; done <= 1;
                    res <= next_res;
                end else begin
                    counter <= counter - 1;
                end
            end else if (done) begin
                if (accept) begin
                    done <= 0;
                end
            end
        end
    end
endmodule