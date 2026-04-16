`timescale 1ns/1ps
module FPU (
    input clk,
    input reset,
    input start,
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    input [5:0] phys_rd_in,
    input [3:0] rob_tag_in,
    input [4:0] arch_rd_in,
    input accept, // CDB arbiter accepted the result
    output reg [63:0] res,
    output busy,
    output reg done,
    output reg [5:0] phys_rd_out,
    output reg [3:0] rob_tag_out,
    output reg [4:0] arch_rd_out,
    output ready,

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
    reg [3:0] s1_rob_tag, s2_rob_tag, s3_rob_tag, s4_rob_tag, s5_rob_tag;
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
    reg s5_held; // Buffer for when accept=0

    assign s1_rd_out = s1_phys_rd; assign s2_rd_out = s2_phys_rd;
    assign s3_rd_out = s3_phys_rd; assign s4_rd_out = s4_phys_rd;
    assign s1_res_out = 0; assign s2_res_out = 0; assign s3_res_out = 0; assign s4_res_out = 0;

    function [6:0] get_lz;
        input [106:0] m;
        begin
            integer k;
            get_lz = 107;
            for (k=106; k>=0; k=k-1) begin
                if (m[k] && get_lz == 107) get_lz = 106-k;
            end
        end
    endfunction

    wire [6:0] lz_val_ext = get_lz(s3_mant_ext);
    wire stall = s5_held && !accept;
    assign ready = !stall; 

    always @(posedge clk) begin
        if (reset) begin
            s1_valid <= 0; s2_valid <= 0; s3_valid <= 0; s4_valid <= 0; s5_valid <= 0;
            done <= 0; res <= 0; phys_rd_out <= 0; rob_tag_out <= 0; arch_rd_out <= 0;
            s5_held <= 0;
        end else begin
            if (s5_held) begin
                if (accept) begin
                    if (!stall && s5_valid) begin
                         done <= 1; res <= s5_res_val; phys_rd_out <= s5_phys_rd; rob_tag_out <= s5_rob_tag; arch_rd_out <= s5_arch_rd; s5_held <= 1;
                    end else begin
                         done <= 0; s5_held <= 0;
                    end
                end
            end else if (s5_valid) begin
                done <= 1; res <= s5_res_val; phys_rd_out <= s5_phys_rd; rob_tag_out <= s5_rob_tag; arch_rd_out <= s5_arch_rd; s5_held <= 1;
            end else done <= 0;

            if (!stall) begin
                s5_valid <= s4_valid; s5_phys_rd <= s4_phys_rd; s5_rob_tag <= s4_rob_tag; s5_arch_rd <= s4_arch_rd;
                if (s4_valid) begin
                    if (s4_special_valid) s5_res_val <= s4_special_bits;
                    else if (s4_zero_result) s5_res_val <= {s4_sign, 63'b0};
                    else begin
                        if (s4_exp[11] || s4_exp >= 2047) s5_res_val <= {s4_sign, 11'h7FF, 52'b0};
                        else s5_res_val <= {s4_sign, s4_exp[10:0], s4_mant_norm[54:3]};
                    end
                end

                s4_valid <= s3_valid; s4_phys_rd <= s3_phys_rd; s4_rob_tag <= s3_rob_tag; s4_arch_rd <= s3_arch_rd; s4_op <= s3_op;
                if (s3_valid) begin
                    s4_special_valid <= s3_special_valid; s4_special_bits <= s3_special_bits; s4_sign <= s3_sign;
                    if (s3_mant_ext == 0) begin s4_zero_result <= 1; s4_exp <= 0; end
                    else begin
                        s4_zero_result <= s3_zero_result;
                        // Normalize such that bit 55 is the leading 1
                        if (s3_op == OP_MULF) begin
                            if (s3_mant_ext[105]) begin s4_mant_norm <= s3_mant_ext[105:50]; s4_exp <= s3_exp + 1; end
                            else begin s4_mant_norm <= s3_mant_ext[104:49]; s4_exp <= s3_exp; end
                        end else if (s3_op == OP_DIVF) begin
                            // For division result of ({m_a, 52 zeros} / m_b):
                            // Result has approx 53 bits. Its leading 1 is around bit 52.
                            // To align bit 55, we shift by lz - (106-55) = lz - 51
                            if (lz_val_ext < 51) begin s4_mant_norm <= s3_mant_ext >> (51 - lz_val_ext); s4_exp <= s3_exp + (51 - lz_val_ext); end
                            else begin s4_mant_norm <= s3_mant_ext << (lz_val_ext - 51); s4_exp <= s3_exp - (lz_val_ext - 51); end
                        end else begin
                            // ADDF/SUBF: leading 1 around bit 55/56
                            if (s3_mant_ext[56]) begin s4_mant_norm <= s3_mant_ext[56:1]; s4_exp <= s3_exp + 1; end
                            else begin s4_mant_norm <= s3_mant_ext[55:0] << (lz_val_ext - (106-55)); s4_exp <= s3_exp - (lz_val_ext - (106-55)); end
                        end
                    end
                end

                s3_valid <= s2_valid; s3_phys_rd <= s2_phys_rd; s3_rob_tag <= s2_rob_tag; s3_arch_rd <= s2_arch_rd; s3_op <= s2_op;
                if (s2_valid) begin
                    s3_special_valid <= 0; s3_zero_result <= 0;
                    case (s2_op)
                        OP_ADDF, OP_SUBF: begin
                            if (s2_a_nan || s2_b_nan) begin s3_special_valid <= 1; s3_special_bits <= 64'h7FF8000000000000; end
                            else if (s2_a_inf || s2_b_inf) begin s3_special_valid <= 1; s3_special_bits <= {s2_sign_large, 11'h7FF, 52'b0}; end
                            else begin
                                s3_exp <= s2_exp_base; s3_sign <= s2_sign_large;
                                if (s2_sign_large == s2_sign_small) s3_mant_ext <= {50'b0, 1'b0, s2_mant_large} + {50'b0, 1'b0, s2_mant_small};
                                else begin
                                    s3_mant_ext <= {50'b0, 1'b0, s2_mant_large} - {50'b0, 1'b0, s2_mant_small};
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

                s2_valid <= s1_valid; s2_phys_rd <= s1_phys_rd; s2_rob_tag <= s1_rob_tag; s2_arch_rd <= s1_arch_rd; s2_op <= s1_op;
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
                        s2_mul_mant_a <= s1_mant_a; s2_mul_mant_b <= s1_mant_b; s2_div_mant_a <= s1_mant_a; s2_div_mant_b <= s1_mant_b;
                    end
                end

                if (start) begin
                    s1_valid <= 1; s1_op <= op; s1_phys_rd <= phys_rd_in; s1_rob_tag <= rob_tag_in; s1_arch_rd <= arch_rd_in;
                    s1_sign_a <= a[63]; s1_sign_b <= b[63]; s1_exp_a <= a[62:52]; s1_exp_b <= b[62:52];
                    s1_mant_a <= (a[62:52] == 0) ? {1'b0, a[51:0]} : {1'b1, a[51:0]}; s1_mant_b <= (b[62:52] == 0) ? {1'b0, b[51:0]} : {1'b1, b[51:0]};
                    s1_a_zero <= (a[62:0] == 0); s1_b_zero <= (b[62:0] == 0); s1_a_inf <= (a[62:52] == 2047 && a[51:0] == 0); s1_b_inf <= (b[62:52] == 2047 && b[51:0] == 0);
                    s1_a_nan <= (a[62:52] == 2047 && a[51:0] != 0); s1_b_nan <= (b[62:52] == 2047 && b[51:0] != 0);
                end else s1_valid <= 0;
            end
        end
    end
endmodule
