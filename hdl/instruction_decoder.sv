module instruction_decoder (
    input [31:0] instruction,
    output [4:0] opcode, rd, rs, rt,
    output [11:0] imm,
    output use_immediate,
    output use_fpu_instruction,
    output is_branch
);
    assign opcode = instruction[31:27];
    assign rd = instruction[26:22];
    assign rs = instruction[21:17];
    assign rt = instruction[16:12];
    assign imm = instruction[11:0];

    assign use_immediate = (
        opcode == 5'h19 | opcode == 5'h1b | 
        opcode == 5'h05 | opcode == 5'h07 | 
        opcode == 5'h10 | opcode == 5'h12 | opcode == 5'h13
    );

    assign use_fpu_instruction = (opcode >= 5'h14 && opcode <= 5'h17);
    assign is_branch = (opcode >= 5'h08 && opcode <= 5'h0e);
endmodule