module FPU (
    input clk,
    input reset,
    input start,
    input [63:0] a,
    input [63:0] b,
    input [4:0] op,
    output reg [63:0] res,
    output reg busy,
    output reg done
);
    localparam OP_ADDF = 5'h14;
    localparam OP_SUBF = 5'h15;
    localparam OP_MULF = 5'h16;
    localparam OP_DIVF = 5'h17;

    reg s1_valid;
    reg [4:0] s1_op;
    reg s1_sign_a;
    reg s1_sign_b;
    reg [10:0] s1_exp_a;
    reg [10:0] s1_exp_b;
    reg [52:0] s1_mant_a;
    reg [52:0] s1_mant_b;
    reg s1_a_zero;
    reg s1_b_zero;
    reg s1_a_inf;
    reg s1_b_inf;
    reg s1_a_nan;
    reg s1_b_nan;

    reg s2_valid;
    reg [4:0] s2_op;
    reg s2_sign_large;
    reg s2_sign_small;
    reg [11:0] s2_exp_base;
    reg [55:0] s2_mant_large;
    reg [55:0] s2_mant_small;
    reg s2_mul_sign;
    reg s2_div_sign;
    reg [11:0] s2_mul_exp;
    reg [11:0] s2_div_exp;
    reg [52:0] s2_mul_mant_a;
    reg [52:0] s2_mul_mant_b;
    reg [52:0] s2_div_mant_a;
    reg [52:0] s2_div_mant_b;
    reg s2_a_zero;
    reg s2_b_zero;
    reg s2_a_inf;
    reg s2_b_inf;
    reg s2_a_nan;
    reg s2_b_nan;

    reg s3_valid;
    reg [4:0] s3_op;
    reg s3_sign;
    reg [11:0] s3_exp;
    reg [106:0] s3_mant_ext;
    reg s3_zero_result;
    reg s3_special_valid;
    reg [63:0] s3_special_bits;

    reg s4_valid;
    reg s4_sign;
    reg [11:0] s4_exp;
    reg [52:0] s4_mant;
    reg s4_guard;
    reg s4_round;
    reg s4_sticky;
    reg s4_zero_result;
    reg s4_special_valid;
    reg [63:0] s4_special_bits;

    reg s5_valid;
    reg [63:0] s5_res;

    integer shift_amt;
    integer lz;
    integer i;

    reg [10:0] exp_a_in;
    reg [10:0] exp_b_in;
    reg [52:0] mant_a_in;
    reg [52:0] mant_b_in;
    reg [11:0] exp_large_tmp;
    reg [55:0] mant_large_tmp;
    reg [55:0] mant_small_tmp;
    reg sign_large_tmp;
    reg sign_small_tmp;
    reg [10:0] exp_delta_tmp;
    reg sticky_tmp;
    reg [56:0] addsub_sum_tmp;
    reg [55:0] addsub_diff_tmp;
    reg [105:0] mul_prod_tmp;
    reg [55:0] div_quot_tmp;
    reg [108:0] div_num_tmp;
    reg [52:0] div_rem_tmp;
    reg [106:0] mant_norm_tmp;
    reg [11:0] exp_norm_tmp;
    reg sign_norm_tmp;
    reg zero_norm_tmp;
    reg [52:0] mant_pack_tmp;
    reg guard_tmp;
    reg round_tmp;
    reg sticky_pack_tmp;
    reg [53:0] rounded_tmp;
    reg [11:0] exp_pack_tmp;
    reg [63:0] pack_tmp;

    always @(posedge clk) begin
        if (reset) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            s5_valid <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            res <= 64'b0;
            s5_res <= 64'b0;
        end else begin
            done <= 1'b0;

            if (s5_valid) begin
                res <= s5_res;
                done <= 1'b1;
            end

            s5_valid <= s4_valid;
            if (s4_valid) begin
                if (s4_special_valid) begin
                    s5_res <= s4_special_bits;
                end else if (s4_zero_result || (s4_exp == 12'd0)) begin
                    s5_res <= 64'b0;
                end else begin
                    rounded_tmp = {1'b0, s4_mant} + ((s4_guard && (s4_round || s4_sticky || s4_mant[0])) ? 54'd1 : 54'd0);
                    exp_pack_tmp = s4_exp;
                    mant_pack_tmp = rounded_tmp[52:0];
                    if (rounded_tmp[53]) begin
                        mant_pack_tmp = rounded_tmp[53:1];
                        exp_pack_tmp = s4_exp + 12'd1;
                    end

                    if (exp_pack_tmp[11] || (exp_pack_tmp >= 12'd2047)) begin
                        s5_res <= {s4_sign, 11'h7FF, 52'b0};
                    end else begin
                        s5_res <= {s4_sign, exp_pack_tmp[10:0], mant_pack_tmp[51:0]};
                    end
                end
            end

            s4_valid <= s3_valid;
            if (s3_valid) begin
                mant_norm_tmp = s3_mant_ext;
                exp_norm_tmp = s3_exp;
                sign_norm_tmp = s3_sign;
                zero_norm_tmp = s3_zero_result;

                if (s3_special_valid) begin
                    s4_zero_result <= 1'b0;
                    s4_sign <= 1'b0;
                    s4_exp <= 12'b0;
                    s4_mant <= 53'b0;
                    s4_guard <= 1'b0;
                    s4_round <= 1'b0;
                    s4_sticky <= 1'b0;
                    s4_special_valid <= 1'b1;
                    s4_special_bits <= s3_special_bits;
                end else if (s3_zero_result || (s3_mant_ext == 107'b0)) begin
                    s4_zero_result <= 1'b1;
                    s4_sign <= s3_sign;
                    s4_exp <= 12'b0;
                    s4_mant <= 53'b0;
                    s4_guard <= 1'b0;
                    s4_round <= 1'b0;
                    s4_sticky <= 1'b0;
                    s4_special_valid <= 1'b0;
                    s4_special_bits <= 64'b0;
                end else begin
                    s4_special_valid <= 1'b0;
                    s4_special_bits <= 64'b0;
                    case (s3_op)
                        OP_MULF: begin
                            if (mant_norm_tmp[105]) begin
                                mant_norm_tmp = mant_norm_tmp >> 1;
                                exp_norm_tmp = exp_norm_tmp + 12'd1;
                            end
                            s4_mant <= mant_norm_tmp[104:52];
                            s4_guard <= mant_norm_tmp[51];
                            s4_round <= mant_norm_tmp[50];
                            s4_sticky <= |mant_norm_tmp[49:0];
                            s4_exp <= exp_norm_tmp;
                            s4_sign <= sign_norm_tmp;
                            s4_zero_result <= 1'b0;
                        end
                        OP_DIVF: begin
                            s4_mant <= mant_norm_tmp[55:3];
                            s4_guard <= mant_norm_tmp[2];
                            s4_round <= mant_norm_tmp[1];
                            s4_sticky <= mant_norm_tmp[0];
                            s4_exp <= exp_norm_tmp;
                            s4_sign <= sign_norm_tmp;
                            s4_zero_result <= 1'b0;
                        end
                        default: begin
                            if (mant_norm_tmp[56]) begin
                                mant_norm_tmp = mant_norm_tmp >> 1;
                                exp_norm_tmp = exp_norm_tmp + 12'd1;
                            end else begin
                                while ((mant_norm_tmp[55] == 1'b0) && (exp_norm_tmp > 0) && (mant_norm_tmp != 0)) begin
                                    mant_norm_tmp = mant_norm_tmp << 1;
                                    exp_norm_tmp = exp_norm_tmp - 12'd1;
                                end
                            end
                            s4_mant <= mant_norm_tmp[55:3];
                            s4_guard <= mant_norm_tmp[2];
                            s4_round <= mant_norm_tmp[1];
                            s4_sticky <= mant_norm_tmp[0];
                            s4_exp <= exp_norm_tmp;
                            s4_sign <= sign_norm_tmp;
                            s4_zero_result <= (mant_norm_tmp == 0);
                        end
                    endcase
                end
            end

            s3_valid <= s2_valid;
            if (s2_valid) begin
                s3_op <= s2_op;
                s3_zero_result <= 1'b0;
                s3_special_valid <= 1'b0;
                s3_special_bits <= 64'b0;
                case (s2_op)
                    OP_ADDF, OP_SUBF: begin
                        if (s2_a_nan || s2_b_nan || (s2_a_inf && s2_b_inf && (s2_sign_large != s2_sign_small))) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= 64'h7FF8000000000000;
                            s3_mant_ext <= 107'b0;
                            s3_sign <= 1'b0;
                            s3_exp <= 12'b0;
                        end else if (s2_a_inf || s2_b_inf) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= {s2_sign_large, 11'h7FF, 52'b0};
                            s3_mant_ext <= 107'b0;
                            s3_sign <= s2_sign_large;
                            s3_exp <= 12'b0;
                        end else begin
                            s3_exp <= s2_exp_base;
                            if (s2_sign_large == s2_sign_small) begin
                                addsub_sum_tmp = {1'b0, s2_mant_large} + {1'b0, s2_mant_small};
                                s3_mant_ext <= {50'b0, addsub_sum_tmp};
                                s3_sign <= s2_sign_large;
                                s3_zero_result <= (addsub_sum_tmp == 0);
                            end else begin
                                if (s2_mant_large >= s2_mant_small) begin
                                    addsub_diff_tmp = s2_mant_large - s2_mant_small;
                                    s3_mant_ext <= {51'b0, addsub_diff_tmp};
                                    s3_sign <= s2_sign_large;
                                    s3_zero_result <= (addsub_diff_tmp == 0);
                                end else begin
                                    addsub_diff_tmp = s2_mant_small - s2_mant_large;
                                    s3_mant_ext <= {51'b0, addsub_diff_tmp};
                                    s3_sign <= s2_sign_small;
                                    s3_zero_result <= (addsub_diff_tmp == 0);
                                end
                            end
                        end
                    end
                    OP_MULF: begin
                        if (s2_a_nan || s2_b_nan || ((s2_a_inf || s2_b_inf) && (s2_a_zero || s2_b_zero))) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= 64'h7FF8000000000000;
                            s3_mant_ext <= 107'b0;
                            s3_sign <= 1'b0;
                            s3_exp <= 12'b0;
                        end else if (s2_a_inf || s2_b_inf) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= {s2_mul_sign, 11'h7FF, 52'b0};
                            s3_mant_ext <= 107'b0;
                            s3_sign <= s2_mul_sign;
                            s3_exp <= 12'b0;
                        end else begin
                            mul_prod_tmp = s2_mul_mant_a * s2_mul_mant_b;
                            s3_sign <= s2_mul_sign;
                            s3_exp <= s2_mul_exp;
                            s3_mant_ext <= {1'b0, mul_prod_tmp};
                            s3_zero_result <= s2_a_zero || s2_b_zero;
                        end
                    end
                    default: begin
                        if (s2_a_nan || s2_b_nan || (s2_a_inf && s2_b_inf) || (s2_a_zero && s2_b_zero)) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= 64'h7FF8000000000000;
                            s3_sign <= 1'b0;
                            s3_exp <= 12'b0;
                            s3_mant_ext <= 107'b0;
                        end else if (s2_b_zero || s2_a_inf) begin
                            s3_special_valid <= 1'b1;
                            s3_special_bits <= {s2_div_sign, 11'h7FF, 52'b0};
                            s3_sign <= s2_div_sign;
                            s3_exp <= 12'b0;
                            s3_mant_ext <= 107'b0;
                        end else if (s2_a_zero || s2_b_inf) begin
                            s3_sign <= s2_div_sign;
                            s3_exp <= 12'b0;
                            s3_mant_ext <= 107'b0;
                            s3_zero_result <= 1'b1;
                        end else begin
                            if (s2_div_mant_a >= s2_div_mant_b) begin
                                div_num_tmp = {s2_div_mant_a, 56'b0} >> 1;
                                s3_exp <= s2_div_exp;
                            end else begin
                                div_num_tmp = {s2_div_mant_a, 56'b0};
                                s3_exp <= s2_div_exp - 12'd1;
                            end
                            div_quot_tmp = div_num_tmp / s2_div_mant_b;
                            div_rem_tmp = div_num_tmp % s2_div_mant_b;
                            if (div_rem_tmp != 0)
                                div_quot_tmp[0] = 1'b1;
                            s3_sign <= s2_div_sign;
                            s3_mant_ext <= {1'b0, div_quot_tmp};
                            s3_zero_result <= 1'b0;
                        end
                    end
                endcase
            end

            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_op <= s1_op;
                s2_a_zero <= s1_a_zero;
                s2_b_zero <= s1_b_zero;
                s2_a_inf <= s1_a_inf;
                s2_b_inf <= s1_b_inf;
                s2_a_nan <= s1_a_nan;
                s2_b_nan <= s1_b_nan;

                if ((s1_op == OP_ADDF) || (s1_op == OP_SUBF)) begin
                    if ((s1_exp_a > s1_exp_b) || ((s1_exp_a == s1_exp_b) && (s1_mant_a >= s1_mant_b))) begin
                        exp_large_tmp = {1'b0, s1_exp_a};
                        mant_large_tmp = {s1_mant_a, 3'b000};
                        mant_small_tmp = {s1_mant_b, 3'b000};
                        sign_large_tmp = s1_sign_a;
                        sign_small_tmp = s1_sign_b ^ (s1_op == OP_SUBF);
                        exp_delta_tmp = s1_exp_a - s1_exp_b;
                    end else begin
                        exp_large_tmp = {1'b0, s1_exp_b};
                        mant_large_tmp = {s1_mant_b, 3'b000};
                        mant_small_tmp = {s1_mant_a, 3'b000};
                        sign_large_tmp = s1_sign_b ^ (s1_op == OP_SUBF);
                        sign_small_tmp = s1_sign_a;
                        exp_delta_tmp = s1_exp_b - s1_exp_a;
                    end

                    sticky_tmp = 1'b0;
                    if (exp_delta_tmp >= 11'd56) begin
                        sticky_tmp = |mant_small_tmp;
                        mant_small_tmp = 56'b0;
                        mant_small_tmp[0] = sticky_tmp;
                    end else if (exp_delta_tmp != 0) begin
                        for (i = 0; i < 56; i = i + 1) begin
                            if (i < exp_delta_tmp) begin
                                sticky_tmp = sticky_tmp | mant_small_tmp[i];
                            end
                        end
                        mant_small_tmp = mant_small_tmp >> exp_delta_tmp;
                        mant_small_tmp[0] = mant_small_tmp[0] | sticky_tmp;
                    end

                    s2_exp_base <= exp_large_tmp;
                    s2_mant_large <= mant_large_tmp;
                    s2_mant_small <= mant_small_tmp;
                    s2_sign_large <= sign_large_tmp;
                    s2_sign_small <= sign_small_tmp;
                end else begin
                    s2_mul_sign <= s1_sign_a ^ s1_sign_b;
                    s2_div_sign <= s1_sign_a ^ s1_sign_b;
                    s2_mul_exp <= {1'b0, s1_exp_a} + {1'b0, s1_exp_b} - 12'd1023;
                    s2_div_exp <= {1'b0, s1_exp_a} - {1'b0, s1_exp_b} + 12'd1023;
                    s2_mul_mant_a <= s1_mant_a;
                    s2_mul_mant_b <= s1_mant_b;
                    s2_div_mant_a <= s1_mant_a;
                    s2_div_mant_b <= s1_mant_b;
                end
            end

            if (start && !busy) begin
                exp_a_in = a[62:52];
                exp_b_in = b[62:52];
                mant_a_in = (exp_a_in == 0) ? {1'b0, a[51:0]} : {1'b1, a[51:0]};
                mant_b_in = (exp_b_in == 0) ? {1'b0, b[51:0]} : {1'b1, b[51:0]};

                s1_valid <= 1'b1;
                s1_op <= op;
                s1_sign_a <= a[63];
                s1_sign_b <= b[63];
                s1_exp_a <= exp_a_in;
                s1_exp_b <= exp_b_in;
                s1_mant_a <= mant_a_in;
                s1_mant_b <= mant_b_in;
                s1_a_zero <= (a[62:0] == 63'b0);
                s1_b_zero <= (b[62:0] == 63'b0);
                s1_a_inf <= (a[62:52] == 11'h7FF) && (a[51:0] == 52'b0);
                s1_b_inf <= (b[62:52] == 11'h7FF) && (b[51:0] == 52'b0);
                s1_a_nan <= (a[62:52] == 11'h7FF) && (a[51:0] != 52'b0);
                s1_b_nan <= (b[62:52] == 11'h7FF) && (b[51:0] != 52'b0);
            end else begin
                s1_valid <= 1'b0;
            end

            busy <= start || s1_valid || s2_valid || s3_valid || s4_valid;
        end
    end
endmodule
