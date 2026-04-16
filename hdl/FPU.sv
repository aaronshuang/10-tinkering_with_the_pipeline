module FPU (
    input clk,
    input reset,
    input start,
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    input [5:0] phys_rd_in,
    input [4:0] arch_rd_in,
    output reg [63:0] res,
    output busy,
    output reg done,
    output reg [5:0] phys_rd_out,
    output reg [4:0] arch_rd_out,

    // Stage internal state exposed as ports
    output reg s1_valid,
    output reg s2_valid,
    output reg s3_valid,
    output reg s4_valid,
    output reg s5_valid,
    output [63:0] s1_res_out,
    output [63:0] s2_res_out,
    output [63:0] s3_res_out,
    output [63:0] s4_res_out,
    output [5:0] s1_rd_out,
    output [5:0] s2_rd_out,
    output [5:0] s3_rd_out,
    output [5:0] s4_rd_out
);
    localparam OP_ADDF = 5'h14;
    localparam OP_SUBF = 5'h15;
    localparam OP_MULF = 5'h16;
    localparam OP_DIVF = 5'h17;

    assign busy = s1_valid || s2_valid || s3_valid || s4_valid || s5_valid;

    reg [4:0] s1_op, s2_op, s3_op, s4_op;
    reg [5:0] s1_phys_rd, s2_phys_rd, s3_phys_rd, s4_phys_rd, s5_phys_rd;
    reg [4:0] s1_arch_rd, s2_arch_rd, s3_arch_rd, s4_arch_rd, s5_arch_rd;
    reg s1_sign_a, s1_sign_b;
    reg [10:0] s1_exp_a, s1_exp_b;
    reg [52:0] s1_mant_a, s1_mant_b;
    reg s1_a_zero, s1_b_zero, s1_a_inf, s1_b_inf, s1_a_nan, s1_b_nan;

    reg s2_sign_large, s2_sign_small, s2_a_nan, s2_b_nan, s2_a_inf, s2_b_inf, s2_a_zero, s2_b_zero;
    reg [11:0] s2_exp_base;
    reg [55:0] s2_mant_large, s2_mant_small;
    reg s2_mul_sign, s2_div_sign;
    reg [11:0] s2_mul_exp, s2_div_exp;
    reg [52:0] s2_mul_mant_a, s2_mul_mant_b, s2_div_mant_a, s2_div_mant_b;

    reg s3_sign, s3_zero_result, s3_special_valid;
    reg [11:0] s3_exp;
    reg [106:0] s3_mant_ext;
    reg [63:0] s3_special_bits;

    reg s4_sign, s4_zero_result, s4_special_valid;
    reg [11:0] s4_exp;
    reg [55:0] s4_mant_norm;
    reg [63:0] s4_special_bits;

    reg [63:0] s5_res_val;

    assign s1_rd_out = s1_phys_rd; assign s2_rd_out = s2_phys_rd;
    assign s3_rd_out = s3_phys_rd; assign s4_rd_out = s4_phys_rd;
    assign s1_res_out = 0; assign s2_res_out = 0; assign s3_res_out = 0; assign s4_res_out = 0;

    function [5:0] get_lz;
        input [55:0] m;
        begin
            if      (m[55]) get_lz = 0;
            else if (m[54]) get_lz = 1;
            else if (m[53]) get_lz = 2;
            else if (m[52]) get_lz = 3;
            else if (m[51]) get_lz = 4;
            else if (m[50]) get_lz = 5;
            else if (m[49]) get_lz = 6;
            else if (m[48]) get_lz = 7;
            else if (m[47]) get_lz = 8;
            else if (m[46]) get_lz = 9;
            else if (m[45]) get_lz = 10;
            else if (m[44]) get_lz = 11;
            else if (m[43]) get_lz = 12;
            else if (m[42]) get_lz = 13;
            else if (m[41]) get_lz = 14;
            else if (m[40]) get_lz = 15;
            else if (m[39]) get_lz = 16;
            else if (m[38]) get_lz = 17;
            else if (m[37]) get_lz = 18;
            else if (m[36]) get_lz = 19;
            else if (m[35]) get_lz = 20;
            else if (m[34]) get_lz = 21;
            else if (m[33]) get_lz = 22;
            else if (m[32]) get_lz = 23;
            else if (m[31]) get_lz = 24;
            else if (m[30]) get_lz = 25;
            else if (m[29]) get_lz = 26;
            else if (m[28]) get_lz = 27;
            else if (m[27]) get_lz = 28;
            else if (m[26]) get_lz = 29;
            else if (m[25]) get_lz = 30;
            else if (m[24]) get_lz = 31;
            else if (m[23]) get_lz = 32;
            else if (m[22]) get_lz = 33;
            else if (m[21]) get_lz = 34;
            else if (m[20]) get_lz = 35;
            else if (m[19]) get_lz = 36;
            else if (m[18]) get_lz = 37;
            else if (m[17]) get_lz = 38;
            else if (m[16]) get_lz = 39;
            else if (m[15]) get_lz = 40;
            else if (m[14]) get_lz = 41;
            else if (m[13]) get_lz = 42;
            else if (m[12]) get_lz = 43;
            else if (m[11]) get_lz = 44;
            else if (m[10]) get_lz = 45;
            else if (m[9])  get_lz = 46;
            else if (m[8])  get_lz = 47;
            else if (m[7])  get_lz = 48;
            else if (m[6])  get_lz = 49;
            else if (m[5])  get_lz = 50;
            else if (m[4])  get_lz = 51;
            else if (m[3])  get_lz = 52;
            else if (m[2])  get_lz = 53;
            else if (m[1])  get_lz = 54;
            else if (m[0])  get_lz = 55;
            else            get_lz = 56;
        end
    endfunction

    wire [5:0] lz_val = get_lz(s3_mant_ext[105:50]); 
    wire [5:0] lz_val_small = get_lz(s3_mant_ext[55:0]); 

    always @(posedge clk) begin
        if (reset) begin
            s1_valid <= 0; s2_valid <= 0; s3_valid <= 0; s4_valid <= 0; s5_valid <= 0;
            done <= 0; res <= 0; phys_rd_out <= 0; arch_rd_out <= 0;
        end else begin
            done <= s5_valid;
            res <= s5_res_val;
            phys_rd_out <= s5_phys_rd;
            arch_rd_out <= s5_arch_rd;

            s5_valid <= s4_valid;
            s5_phys_rd <= s4_phys_rd;
            s5_arch_rd <= s4_arch_rd;
            if (s4_valid) begin
                if (s4_special_valid) s5_res_val <= s4_special_bits;
                else if (s4_zero_result) s5_res_val <= {s4_sign, 63'b0};
                else begin
                    if (s4_exp[11] || s4_exp >= 11'h7FF) s5_res_val <= {s4_sign, 11'h7FF, 52'b0};
                    else s5_res_val <= {s4_sign, s4_exp[10:0], s4_mant_norm[54:3]};
                end
            end

            s4_valid <= s3_valid;
            s4_phys_rd <= s3_phys_rd;
            s4_arch_rd <= s3_arch_rd;
            s4_op <= s3_op;
            if (s3_valid) begin
                s4_special_valid <= s3_special_valid; s4_special_bits <= s3_special_bits; s4_sign <= s3_sign;
                if (s3_op == OP_MULF) begin
                    if (s3_mant_ext[105]) begin s4_mant_norm <= s3_mant_ext[105:50]; s4_exp <= s3_exp + 1; end
                    else begin s4_mant_norm <= s3_mant_ext[104:49]; s4_exp <= s3_exp; end
                    s4_zero_result <= s3_zero_result;
                end else begin 
                    if (s3_mant_ext[56]) begin s4_mant_norm <= s3_mant_ext[56:1]; s4_exp <= s3_exp + 1; s4_zero_result <= 0; end
                    else if (s3_mant_ext[55:0] == 0) begin s4_zero_result <= 1; s4_exp <= 0; end
                    else begin s4_mant_norm <= s3_mant_ext[55:0] << lz_val_small; s4_exp <= s3_exp - lz_val_small; s4_zero_result <= 0; end
                end
            end

            s3_valid <= s2_valid;
            s3_phys_rd <= s2_phys_rd;
            s3_arch_rd <= s2_arch_rd;
            s3_op <= s2_op;
            if (s2_valid) begin
                s3_special_valid <= 0; s3_zero_result <= 0;
                case (s2_op)
                    OP_ADDF, OP_SUBF: begin
                        if (s2_a_nan || s2_b_nan) begin s3_special_valid <= 1; s3_special_bits <= 64'h7FF8000000000000; end
                        else if (s2_a_inf || s2_b_inf) begin s3_special_valid <= 1; s3_special_bits <= {s2_sign_large, 11'h7FF, 52'b0}; end
                        else begin
                            s3_exp <= s2_exp_base; s3_sign <= s2_sign_large;
                            if (s2_sign_large == s2_sign_small) s3_mant_ext <= {1'b0, s2_mant_large} + {1'b0, s2_mant_small};
                            else begin
                                s3_mant_ext <= {1'b0, s2_mant_large} - {1'b0, s2_mant_small};
                                if (s2_mant_large == s2_mant_small) s3_zero_result <= 1;
                            end
                        end
                    end
                    OP_MULF: begin
                        if (s2_a_nan || s2_b_nan) begin s3_special_valid <= 1; s3_special_bits <= 64'h7FF8000000000000; end
                        else begin s3_sign <= s2_mul_sign; s3_exp <= s2_mul_exp; s3_mant_ext <= s2_mul_mant_a * s2_mul_mant_b; s3_zero_result <= s2_a_zero || s2_b_zero; end
                    end
                    OP_DIVF: begin
                        if (s2_b_zero) begin s3_special_valid <= 1; s3_special_bits <= {s2_div_sign, 11'h7FF, 52'b0}; end
                        else begin s3_sign <= s2_div_sign; s3_exp <= s2_div_exp; s3_mant_ext <= ({s2_div_mant_a, 52'b0} / s2_div_mant_b); end
                        s3_zero_result <= s2_a_zero;
                    end
                endcase
            end

            s2_valid <= s1_valid; s2_phys_rd <= s1_phys_rd; s2_arch_rd <= s1_arch_rd; s2_op <= s1_op;
            if (s1_valid) begin
                s2_a_nan <= s1_a_nan; s2_b_nan <= s1_b_nan; s2_a_inf <= s1_a_inf; s2_b_inf <= s1_b_inf; s2_a_zero <= s1_a_zero; s2_b_zero <= s1_b_zero;
                if (s1_op == OP_ADDF || s1_op == OP_SUBF) begin
                    if (s1_exp_a > s1_exp_b || (s1_exp_a == s1_exp_b && s1_mant_a >= s1_mant_b)) begin
                        s2_sign_large <= s1_sign_a; s2_sign_small <= s1_sign_b ^ (s1_op == OP_SUBF); s2_exp_base <= s1_exp_a;
                        s2_mant_large <= s1_mant_a << 3; s2_mant_small <= (s1_mant_b << 3) >> (s1_exp_a - s1_exp_b);
                    end else begin
                        s2_sign_large <= s1_sign_b ^ (s1_op == OP_SUBF); s2_sign_small <= s1_sign_a; s2_exp_base <= s1_exp_b;
                        s2_mant_large <= s1_mant_b << 3; s2_mant_small <= (s1_mant_a << 3) >> (s1_exp_b - s1_exp_a);
                    end
                end else begin
                    s2_mul_sign <= s1_sign_a ^ s1_sign_b; s2_div_sign <= s1_sign_a ^ s1_sign_b;
                    s2_mul_exp <= s1_exp_a + s1_exp_b - 1023; s2_div_exp <= s1_exp_a - s1_exp_b + 1023;
                    s2_mul_mant_a <= s1_mant_a; s2_mul_mant_b <= s1_mant_b;
                    s2_div_mant_a <= s1_mant_a; s2_div_mant_b <= s1_mant_b;
                end
            end

            if (start) begin
                s1_valid <= 1; s1_op <= op; s1_phys_rd <= phys_rd_in; s1_arch_rd <= arch_rd_in;
                s1_sign_a <= a[63]; s1_sign_b <= b[63];
                s1_exp_a <= a[62:52]; s1_exp_b <= b[62:52];
                s1_mant_a <= (a[62:52] == 0) ? {1'b0, a[51:0]} : {1'b1, a[51:0]};
                s1_mant_b <= (b[62:52] == 0) ? {1'b0, b[51:0]} : {1'b1, b[51:0]};
                s1_a_zero <= (a[62:0] == 0); s1_b_zero <= (b[62:0] == 0);
                s1_a_inf <= (a[62:52] == 2047 && a[51:0] == 0); s1_b_inf <= (b[62:52] == 2047 && b[51:0] == 0);
                s1_a_nan <= (a[62:52] == 2047 && a[51:0] != 0); s1_b_nan <= (b[62:52] == 2047 && b[51:0] != 0);
            end else s1_valid <= 0;
        end
    end
endmodule
