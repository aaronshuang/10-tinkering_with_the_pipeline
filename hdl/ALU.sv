module ALU (
    input clk,
    input reset,
    input start,
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    output [63:0] res,
    output reg busy,
    output reg done
);
    localparam OP_MUL = 5'h1C;
    localparam OP_DIV = 5'h1D;

    reg [3:0] counter;
    reg [63:0] latched_res;

    always @(*) begin
        case (op)
            5'h00: latched_res = a & b;
            5'h01: latched_res = a | b;
            5'h02: latched_res = a ^ b;
            5'h03: latched_res = ~a;
            5'h18, 5'h19: latched_res = a + b;
            5'h10, 5'h13: latched_res = a + b;
            5'h1a, 5'h1b: latched_res = a - b;
            5'h1c: latched_res = a * b;
            5'h1d: latched_res = (b != 0) ? (a / b) : 64'b0;
            5'h04, 5'h05: latched_res = a >> b[5:0];
            5'h06, 5'h07: latched_res = a << b[5:0];
            5'h11: latched_res = a;
            5'h12: latched_res = {a[63:12], b[11:0]};
            default: latched_res = 64'b0;
        endcase
    end

    assign res = latched_res;

    always @(posedge clk) begin
        if (reset) begin
            counter <= 0;
            busy <= 0;
            done <= 0;
        end else begin
            if (start && !busy) begin
                if (op == OP_MUL || op == OP_DIV) begin
                    busy <= 1;
                    done <= 0;
                    counter <= (op == OP_MUL) ? 4'd3 : 4'd7; 
                end else begin
                    busy <= 0;
                    done <= 1;
                end
            end else if (busy) begin
                if (counter == 0) begin
                    busy <= 0;
                    done <= 1;
                end else begin
                    counter <= counter - 1;
                end
            end else begin
                done <= 0;
            end
        end
    end
endmodule