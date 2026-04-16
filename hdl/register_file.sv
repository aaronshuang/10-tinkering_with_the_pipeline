module register_file (
    input clk,
    input reset,
    input [63:0] phys_data0,
    input [63:0] phys_data1,
    input [5:0] rd0,
    input [5:0] rs0,
    input [5:0] rt0,
    input [5:0] rd1,
    input [5:0] rs1,
    input [5:0] rt1,
    input [5:0] phys_write_rd0,
    input [5:0] phys_write_rd1,
    input phys_write_enable0,
    input phys_write_enable1,
    
    // FPU Write Ports
    input [63:0] fpu_data0,
    input [63:0] fpu_data1,
    input [5:0] fpu_write_rd0,
    input [5:0] fpu_write_rd1,
    input [4:0] fpu_arch_rd0,
    input [4:0] fpu_arch_rd1,
    input fpu_write_enable0,
    input fpu_write_enable1,

    input [63:0] commit_data0,
    input [63:0] commit_data1,
    input [4:0] commit_arch_rd0,
    input [4:0] commit_arch_rd1,
    input commit_enable0,
    input commit_enable1,
    input commit_is_fpu0,
    input commit_is_fpu1,
    output reg [63:0] rd0_val, rs0_val, rt0_val,
    output reg [63:0] rd1_val, rs1_val, rt1_val,
    output [63:0] r31_val
);
    reg [63:0] registers [0:31];
    reg [63:0] temp_registers [0:31];

    always @(*) begin
        rd0_val = (rd0 < 6'd32) ? registers[rd0[4:0]] : temp_registers[rd0[4:0]];
        rs0_val = (rs0 < 6'd32) ? registers[rs0[4:0]] : temp_registers[rs0[4:0]];
        rt0_val = (rt0 < 6'd32) ? registers[rt0[4:0]] : temp_registers[rt0[4:0]];
        rd1_val = (rd1 < 6'd32) ? registers[rd1[4:0]] : temp_registers[rd1[4:0]];
        rs1_val = (rs1 < 6'd32) ? registers[rs1[4:0]] : temp_registers[rs1[4:0]];
        rt1_val = (rt1 < 6'd32) ? registers[rt1[4:0]] : temp_registers[rt1[4:0]];

        // Port 0 bypass
        if (phys_write_enable0) begin
            if (phys_write_rd0 == rd0) rd0_val = phys_data0;
            if (phys_write_rd0 == rs0) rs0_val = phys_data0;
            if (phys_write_rd0 == rt0) rt0_val = phys_data0;
            if (phys_write_rd0 == rd1) rd1_val = phys_data0;
            if (phys_write_rd0 == rs1) rs1_val = phys_data0;
            if (phys_write_rd0 == rt1) rt1_val = phys_data0;
        end

        // Port 1 bypass
        if (phys_write_enable1) begin
            if (phys_write_rd1 == rd0) rd0_val = phys_data1;
            if (phys_write_rd1 == rs0) rs0_val = phys_data1;
            if (phys_write_rd1 == rt0) rt0_val = phys_data1;
            if (phys_write_rd1 == rd1) rd1_val = phys_data1;
            if (phys_write_rd1 == rs1) rs1_val = phys_data1;
            if (phys_write_rd1 == rt1) rt1_val = phys_data1;
        end

        // FPU Port 0 bypass
        if (fpu_write_enable0) begin
            if (fpu_write_rd0 == rd0) rd0_val = fpu_data0;
            if (fpu_write_rd0 == rs0) rs0_val = fpu_data0;
            if (fpu_write_rd0 == rt0) rt0_val = fpu_data0;
            if (fpu_write_rd0 == rd1) rd1_val = fpu_data0;
            if (fpu_write_rd0 == rs1) rs1_val = fpu_data0;
            if (fpu_write_rd0 == rt1) rt1_val = fpu_data0;
        end

        // FPU Port 1 bypass
        if (fpu_write_enable1) begin
            if (fpu_write_rd1 == rd0) rd0_val = fpu_data1;
            if (fpu_write_rd1 == rs0) rs0_val = fpu_data1;
            if (fpu_write_rd1 == rt0) rt0_val = fpu_data1;
            if (fpu_write_rd1 == rd1) rd1_val = fpu_data1;
            if (fpu_write_rd1 == rs1) rs1_val = fpu_data1;
            if (fpu_write_rd1 == rt1) rt1_val = fpu_data1;
        end

        if (commit_enable0) begin
            if ((rd0 < 6'd32) && (commit_arch_rd0 == rd0[4:0])) rd0_val = commit_data0;
            if ((rs0 < 6'd32) && (commit_arch_rd0 == rs0[4:0])) rs0_val = commit_data0;
            if ((rt0 < 6'd32) && (commit_arch_rd0 == rt0[4:0])) rt0_val = commit_data0;
            if ((rd1 < 6'd32) && (commit_arch_rd0 == rd1[4:0])) rd1_val = commit_data0;
            if ((rs1 < 6'd32) && (commit_arch_rd0 == rs1[4:0])) rs1_val = commit_data0;
            if ((rt1 < 6'd32) && (commit_arch_rd0 == rt1[4:0])) rt1_val = commit_data0;
        end

        if (commit_enable1) begin
            if ((rd0 < 6'd32) && (commit_arch_rd1 == rd0[4:0])) rd0_val = commit_data1;
            if ((rs0 < 6'd32) && (commit_arch_rd1 == rs0[4:0])) rs0_val = commit_data1;
            if ((rt0 < 6'd32) && (commit_arch_rd1 == rt0[4:0])) rt0_val = commit_data1;
            if ((rd1 < 6'd32) && (commit_arch_rd1 == rd1[4:0])) rd1_val = commit_data1;
            if ((rs1 < 6'd32) && (commit_arch_rd1 == rs1[4:0])) rs1_val = commit_data1;
            if ((rt1 < 6'd32) && (commit_arch_rd1 == rt1[4:0])) rt1_val = commit_data1;
        end
    end
    assign r31_val = registers[31];

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 31; i = i + 1) begin
                registers[i] <= 64'b0;
            end
            registers[31] <= 64'd524288;

            for (i = 0; i < 32; i = i + 1) begin
                temp_registers[i] <= 64'b0;
            end
        end else begin
            if (phys_write_enable0) begin
                if (phys_write_rd0 < 6'd32)
                    registers[phys_write_rd0[4:0]] <= phys_data0;
                else
                    temp_registers[phys_write_rd0[4:0]] <= phys_data0;
            end

            if (phys_write_enable1) begin
                if (phys_write_rd1 < 6'd32)
                    registers[phys_write_rd1[4:0]] <= phys_data1;
                else
                    temp_registers[phys_write_rd1[4:0]] <= phys_data1;
            end

            if (fpu_write_enable0) begin
                if (fpu_write_rd0 < 6'd32)
                    registers[fpu_write_rd0[4:0]] <= fpu_data0;
                else begin
                    temp_registers[fpu_write_rd0[4:0]] <= fpu_data0;
                    registers[fpu_arch_rd0] <= fpu_data0; // Architectural commit
                end
            end

            if (fpu_write_enable1) begin
                if (fpu_write_rd1 < 6'd32)
                    registers[fpu_write_rd1[4:0]] <= fpu_data1;
                else begin
                    temp_registers[fpu_write_rd1[4:0]] <= fpu_data1;
                    registers[fpu_arch_rd1] <= fpu_data1; // Architectural commit
                end
            end

            if (commit_enable0 && !commit_is_fpu0)
                registers[commit_arch_rd0] <= commit_data0;
            if (commit_enable1 && !commit_is_fpu1)
                registers[commit_arch_rd1] <= commit_data1;
        end
    end
endmodule
