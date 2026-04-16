module register_file (
    input clk,
    input reset,
    input [63:0] data0,
    input [63:0] data1,
    input [4:0] rd0,
    input [4:0] rs0,
    input [4:0] rt0,
    input [4:0] rd1,
    input [4:0] rs1,
    input [4:0] rt1,
    input [4:0] write_rd0,
    input [4:0] write_rd1,
    input write_enable0,
    input write_enable1,
    output [63:0] rd0_val, rs0_val, rt0_val,
    output [63:0] rd1_val, rs1_val, rt1_val,
    output [63:0] r31_val
);
    reg [63:0] registers [0:31];

    wire [63:0] rd0_bypass0 = (write_enable0 && (write_rd0 == rd0)) ? data0 : registers[rd0];
    wire [63:0] rs0_bypass0 = (write_enable0 && (write_rd0 == rs0)) ? data0 : registers[rs0];
    wire [63:0] rt0_bypass0 = (write_enable0 && (write_rd0 == rt0)) ? data0 : registers[rt0];
    wire [63:0] rd1_bypass0 = (write_enable0 && (write_rd0 == rd1)) ? data0 : registers[rd1];
    wire [63:0] rs1_bypass0 = (write_enable0 && (write_rd0 == rs1)) ? data0 : registers[rs1];
    wire [63:0] rt1_bypass0 = (write_enable0 && (write_rd0 == rt1)) ? data0 : registers[rt1];

    assign rd0_val = (write_enable1 && (write_rd1 == rd0)) ? data1 : rd0_bypass0;
    assign rs0_val = (write_enable1 && (write_rd1 == rs0)) ? data1 : rs0_bypass0;
    assign rt0_val = (write_enable1 && (write_rd1 == rt0)) ? data1 : rt0_bypass0;
    assign rd1_val = (write_enable1 && (write_rd1 == rd1)) ? data1 : rd1_bypass0;
    assign rs1_val = (write_enable1 && (write_rd1 == rs1)) ? data1 : rs1_bypass0;
    assign rt1_val = (write_enable1 && (write_rd1 == rt1)) ? data1 : rt1_bypass0;
    assign r31_val = registers[31];

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 31; i = i + 1) begin
                registers[i] <= 64'b0;
            end
            registers[31] <= 64'd524288;
        end else begin
            if (write_enable0) begin
                registers[write_rd0] <= data0;
            end
            if (write_enable1) begin
                registers[write_rd1] <= data1;
            end
        end
    end
endmodule
