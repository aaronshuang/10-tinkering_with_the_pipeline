module FPU (
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

    reg [3:0] counter;
    reg sign_a, sign_b, sign_res;
    reg [10:0] exp_a, exp_b, exp_res;
    reg [10:0] eff_exp_a, eff_exp_b; 

    reg [55:0] frac_a, frac_b; 
    reg [56:0] frac_add_res; 

    reg [52:0] m_a, m_b; 
    reg signed [12:0] signed_exp; 
    reg [106:0] raw_mul_res; 
    reg [107:0] div_num; 
    reg [56:0] raw_div_res; 

    reg [10:0] exp_diff;
    integer i;
    reg [5:0] shift_amt;
    reg [55:0] shift_mask;
    reg [106:0] mul_shift_mask; 

    reg G, R, S, LSB;
    reg round_up;

    reg a_is_nan, b_is_nan, a_is_inf, b_is_inf, a_is_zero, b_is_zero;

    reg [63:0] latched_res;

    always @(*) begin
        latched_res = 64'b0;

        sign_a = a[63];
        sign_b = b[63];

        exp_a = a[62:52];
        exp_b = b[62:52];
        eff_exp_a = (exp_a == 0) ? 11'd1 : exp_a;
        eff_exp_b = (exp_b == 0) ? 11'd1 : exp_b;

        frac_a = { (exp_a != 0), a[51:0], 3'b000 };
        frac_b = { (exp_b != 0), b[51:0], 3'b000 };

        a_is_nan = (exp_a == 11'h7FF) && (a[51:0] != 0);
        b_is_nan = (exp_b == 11'h7FF) && (b[51:0] != 0);
        a_is_inf = (exp_a == 11'h7FF) && (a[51:0] == 0);
        b_is_inf = (exp_b == 11'h7FF) && (b[51:0] == 0);
        a_is_zero = (exp_a == 0) && (a[51:0] == 0);
        b_is_zero = (exp_b == 0) && (b[51:0] == 0);

        case (op)
            5'h14, 5'h15: begin 
                if (op == 5'h15) sign_b = ~sign_b;

                if (eff_exp_a > eff_exp_b) begin
                    exp_diff = eff_exp_a - eff_exp_b;
                    exp_res  = eff_exp_a;
                    if (exp_diff > 55) begin
                        frac_b = {55'b0, |frac_b[55:0]};
                    end else begin
                        shift_mask = (56'd1 << exp_diff) - 56'd1;
                        frac_b = (frac_b >> exp_diff) | {55'b0, |(frac_b & shift_mask)};
                    end
                end else if (eff_exp_b > eff_exp_a) begin
                    exp_diff = eff_exp_b - eff_exp_a;
                    exp_res  = eff_exp_b;
                    if (exp_diff > 55) begin
                        frac_a = {55'b0, |frac_a[55:0]};
                    end else begin
                        shift_mask = (56'd1 << exp_diff) - 56'd1;
                        frac_a = (frac_a >> exp_diff) | {55'b0, |(frac_a & shift_mask)};
                    end
                end else begin
                    exp_res = eff_exp_a;
                end

                if (sign_a == sign_b) begin
                    frac_add_res = {1'b0, frac_a} + {1'b0, frac_b};
                    sign_res  = sign_a;
                end else begin
                    if (frac_a >= frac_b) begin
                        frac_add_res = {1'b0, frac_a} - {1'b0, frac_b};
                        sign_res  = sign_a;
                    end else begin
                        frac_add_res = {1'b0, frac_b} - {1'b0, frac_a};
                        sign_res  = sign_b;
                    end
                end
                
                if (frac_add_res == 0) begin
                    latched_res = 64'b0; 
                end else begin
                    if (frac_add_res[56]) begin 
                        frac_add_res = (frac_add_res >> 1) | {56'b0, frac_add_res[0]};
                        exp_res = exp_res + 1;
                    end else begin
                        for (i = 55; i >= 0; i = i - 1) begin
                            if (frac_add_res[55] == 0 && exp_res > 0) begin
                                frac_add_res = frac_add_res << 1;
                                exp_res = exp_res - 1;
                            end
                        end
                    end

                    LSB = frac_add_res[3]; 
                    G = frac_add_res[2];
                    R = frac_add_res[1];
                    S = frac_add_res[0];
                    round_up = G & (R | S | LSB);
                    
                    if (round_up) begin
                        frac_add_res = frac_add_res + 4'b1000;
                        if (frac_add_res[56]) begin
                            frac_add_res = frac_add_res >> 1;
                            exp_res = exp_res + 1;
                        end
                    end

                    latched_res = {sign_res, exp_res, frac_add_res[54:3]};
                end
            end
            
            5'h16: begin 
                sign_res = sign_a ^ sign_b;
                m_a = { (exp_a != 0), a[51:0] };
                m_b = { (exp_b != 0), b[51:0] };

                if (a_is_nan || b_is_nan) begin
                    latched_res = {1'b0, 11'h7FF, 52'h8000000000000}; 
                end else if ((a_is_inf && b_is_zero) || (a_is_zero && b_is_inf)) begin
                    latched_res = {1'b0, 11'h7FF, 52'h8000000000000}; 
                end else if (a_is_inf || b_is_inf) begin
                    latched_res = {sign_res, 11'h7FF, 52'b0}; 
                end else if (a_is_zero || b_is_zero) begin
                    latched_res = {sign_res, 63'b0}; 
                end else begin
                    signed_exp = eff_exp_a + eff_exp_b - 1023 + 1; 
                    raw_mul_res = m_a * m_b;
                    
                    if (raw_mul_res != 0) begin
                        for (i = 105; i >= 0; i = i - 1) begin
                            if (raw_mul_res[105] == 0 && signed_exp > 1) begin
                                raw_mul_res = raw_mul_res << 1;
                                signed_exp = signed_exp - 1;
                            end
                        end
                        
                        if (signed_exp < 1) begin
                            shift_amt = 1 - signed_exp;
                            if (shift_amt > 106) begin
                                raw_mul_res = 0;
                            end else begin
                                mul_shift_mask = (107'd1 << shift_amt) - 1;
                                S = |(raw_mul_res & mul_shift_mask);
                                raw_mul_res = (raw_mul_res >> shift_amt) | {106'b0, S};
                            end
                            signed_exp = 0;
                        end else if (raw_mul_res[105] == 0) begin
                            signed_exp = 0; 
                        end
                    end

                    LSB = raw_mul_res[53];
                    G = raw_mul_res[52];
                    R = raw_mul_res[51];
                    S = |raw_mul_res[50:0];
                    round_up = G & (R | S | LSB);

                    if (round_up) begin
                        raw_mul_res = raw_mul_res + (107'b1 << 53);
                        if (raw_mul_res[106]) begin 
                            raw_mul_res = raw_mul_res >> 1;
                            signed_exp = signed_exp + 1;
                        end
                    end

                    if (signed_exp >= 2047) exp_res = 11'h7FF; 
                    else exp_res = signed_exp[10:0];

                    latched_res = {sign_res, exp_res, raw_mul_res[104:53]};
                end
            end
            
            5'h17: begin 
                sign_res = sign_a ^ sign_b;
                m_a = { (exp_a != 0), a[51:0] };
                m_b = { (exp_b != 0), b[51:0] };

                if (a_is_nan || b_is_nan) begin
                    latched_res = {1'b0, 11'h7FF, 52'h8000000000000}; 
                end else if (a_is_inf && b_is_inf) begin
                    latched_res = {1'b0, 11'h7FF, 52'h8000000000000}; 
                end else if (a_is_zero && b_is_zero) begin
                    latched_res = {1'b0, 11'h7FF, 52'h8000000000000}; 
                end else if (a_is_inf || b_is_zero) begin
                    latched_res = {sign_res, 11'h7FF, 52'b0}; 
                end else if (b_is_inf || a_is_zero) begin
                    latched_res = {sign_res, 63'b0}; 
                end else begin
                    signed_exp = eff_exp_a - eff_exp_b + 1023;
                    div_num = {m_a, 55'b0};
                    if (m_b != 0) begin
                        raw_div_res = div_num / m_b;
                        S = |(div_num % m_b);
                    end else begin
                        raw_div_res = 57'h1FFFFFFFFFFFFFF;
                        S = 0;
                    end
                    
                    if (raw_div_res != 0) begin
                        for (i = 55; i >= 0; i = i - 1) begin
                            if (raw_div_res[55] == 0 && signed_exp > 1) begin
                                raw_div_res = raw_div_res << 1;
                                signed_exp = signed_exp - 1;
                            end
                        end
                        
                        if (signed_exp < 1) begin
                            shift_amt = 1 - signed_exp;
                            if (shift_amt > 56) begin
                                raw_div_res = 0;
                            end else begin
                                shift_mask = (57'd1 << shift_amt) - 1;
                                S = |(raw_div_res & shift_mask) | S;
                                raw_div_res = (raw_div_res >> shift_amt) | {56'b0, S};
                            end
                            signed_exp = 0;
                        end else if (raw_div_res[55] == 0) begin
                            signed_exp = 0;
                        end
                    end

                    LSB = raw_div_res[3];
                    G = raw_div_res[2];
                    R = raw_div_res[1];
                    S = S | raw_div_res[0]; 
                    
                    round_up = G & (R | S | LSB);

                    if (round_up) begin
                        raw_div_res = raw_div_res + 4'b1000;
                        if (raw_div_res[56]) begin 
                            raw_div_res = raw_div_res >> 1;
                            signed_exp = signed_exp + 1;
                        end
                    end

                    if (signed_exp >= 2047) exp_res = 11'h7FF; 
                    else exp_res = signed_exp[10:0];

                    latched_res = {sign_res, exp_res, raw_div_res[54:3]};
                end
            end
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
                if (op == 5'h16 || op == 5'h17) begin
                    busy <= 1;
                    done <= 0;
                    counter <= (op == 5'h16) ? 4'd3 : 4'd7;
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