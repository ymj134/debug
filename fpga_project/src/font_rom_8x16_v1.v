`timescale 1ns / 1ps

/*********************************************************************************
* Module       : font_rom_8x16_v1
* Description  :
*   8x16 单色字体 ROM（组合逻辑）
*
* Interface:
*   i_char : ASCII 字符
*   i_row  : 字模的第几行（0~15）
*   o_bits : 当前行 8bit 点阵，bit[7] 为最左像素，bit[0] 为最右像素
*
* Notes:
*   1) 这版只实现当前 OSD 菜单需要的字符子集
*   2) 未实现的字符默认输出全 0
*   3) 字体风格偏工程化，优先保证“能看清”
*********************************************************************************/

module font_rom_8x16_v1
(
    input      [7:0] i_char,
    input      [3:0] i_row,
    output reg [7:0] o_bits
);

    always @(*) begin
        o_bits = 8'h00;

        case (i_char)

            // -----------------------------------------------------------------
            // space
            // -----------------------------------------------------------------
            8'h20: begin
                o_bits = 8'h00;
            end

            // -----------------------------------------------------------------
            // '>'
            // -----------------------------------------------------------------
            8'h3E: begin
                case (i_row)
                    4'd0 : o_bits = 8'h00;
                    4'd1 : o_bits = 8'h00;
                    4'd2 : o_bits = 8'h10;
                    4'd3 : o_bits = 8'h18;
                    4'd4 : o_bits = 8'h1C;
                    4'd5 : o_bits = 8'h1E;
                    4'd6 : o_bits = 8'h1C;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h10;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h1C;
                    4'd11: o_bits = 8'h1E;
                    4'd12: o_bits = 8'h1C;
                    4'd13: o_bits = 8'h18;
                    4'd14: o_bits = 8'h10;
                    4'd15: o_bits = 8'h00;
                    default: o_bits = 8'h00;
                endcase
            end

            // -----------------------------------------------------------------
            // '?'
            // -----------------------------------------------------------------
            8'h3F: begin
                case (i_row)
                    4'd0 : o_bits = 8'h00;
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h06;
                    4'd5 : o_bits = 8'h0C;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h00;
                    4'd11: o_bits = 8'h18;
                    4'd12: o_bits = 8'h18;
                    4'd13: o_bits = 8'h00;
                    4'd14: o_bits = 8'h00;
                    4'd15: o_bits = 8'h00;
                    default: o_bits = 8'h00;
                endcase
            end

            // -----------------------------------------------------------------
            // digits 0~9
            // -----------------------------------------------------------------
            8'h30: begin // 0
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h6E;
                    4'd4 : o_bits = 8'h76;
                    4'd5 : o_bits = 8'h76;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h31: begin // 1
                case (i_row)
                    4'd1 : o_bits = 8'h18;
                    4'd2 : o_bits = 8'h38;
                    4'd3 : o_bits = 8'h18;
                    4'd4 : o_bits = 8'h18;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h7E;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h32: begin // 2
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h06;
                    4'd4 : o_bits = 8'h0C;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h30;
                    4'd7 : o_bits = 8'h60;
                    4'd8 : o_bits = 8'h60;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h7E;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h33: begin // 3
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h06;
                    4'd4 : o_bits = 8'h06;
                    4'd5 : o_bits = 8'h1C;
                    4'd6 : o_bits = 8'h06;
                    4'd7 : o_bits = 8'h06;
                    4'd8 : o_bits = 8'h06;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h34: begin // 4
                case (i_row)
                    4'd1 : o_bits = 8'h0C;
                    4'd2 : o_bits = 8'h1C;
                    4'd3 : o_bits = 8'h3C;
                    4'd4 : o_bits = 8'h6C;
                    4'd5 : o_bits = 8'h4C;
                    4'd6 : o_bits = 8'h7E;
                    4'd7 : o_bits = 8'h0C;
                    4'd8 : o_bits = 8'h0C;
                    4'd9 : o_bits = 8'h0C;
                    4'd10: o_bits = 8'h1E;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h35: begin // 5
                case (i_row)
                    4'd1 : o_bits = 8'h7E;
                    4'd2 : o_bits = 8'h60;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h7C;
                    4'd5 : o_bits = 8'h06;
                    4'd6 : o_bits = 8'h06;
                    4'd7 : o_bits = 8'h06;
                    4'd8 : o_bits = 8'h06;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h36: begin // 6
                case (i_row)
                    4'd1 : o_bits = 8'h1C;
                    4'd2 : o_bits = 8'h30;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h7C;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h37: begin // 7
                case (i_row)
                    4'd1 : o_bits = 8'h7E;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h06;
                    4'd4 : o_bits = 8'h0C;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h18;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h38: begin // 8
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h3C;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            8'h39: begin // 9
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h3E;
                    4'd7 : o_bits = 8'h06;
                    4'd8 : o_bits = 8'h0C;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h38;
                    default: o_bits = 8'h00;
                endcase
            end

            // -----------------------------------------------------------------
            // A
            // -----------------------------------------------------------------
            8'h41: begin
                case (i_row)
                    4'd1 : o_bits = 8'h18;
                    4'd2 : o_bits = 8'h3C;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h7E;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h66;
                    default: o_bits = 8'h00;
                endcase
            end

            // B
            8'h42: begin
                case (i_row)
                    4'd1 : o_bits = 8'h7C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h7C;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h7C;
                    default: o_bits = 8'h00;
                endcase
            end

            // C
            8'h43: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h60;
                    4'd6 : o_bits = 8'h60;
                    4'd7 : o_bits = 8'h60;
                    4'd8 : o_bits = 8'h60;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // D
            8'h44: begin
                case (i_row)
                    4'd1 : o_bits = 8'h78;
                    4'd2 : o_bits = 8'h6C;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h6C;
                    4'd10: o_bits = 8'h78;
                    default: o_bits = 8'h00;
                endcase
            end

            // E
            8'h45: begin
                case (i_row)
                    4'd1 : o_bits = 8'h7E;
                    4'd2 : o_bits = 8'h60;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h7C;
                    4'd6 : o_bits = 8'h60;
                    4'd7 : o_bits = 8'h60;
                    4'd8 : o_bits = 8'h60;
                    4'd9 : o_bits = 8'h60;
                    4'd10: o_bits = 8'h7E;
                    default: o_bits = 8'h00;
                endcase
            end

            // G
            8'h47: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h6E;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3E;
                    default: o_bits = 8'h00;
                endcase
            end

            // I
            8'h49: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h18;
                    4'd3 : o_bits = 8'h18;
                    4'd4 : o_bits = 8'h18;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // L
            8'h4C: begin
                case (i_row)
                    4'd1 : o_bits = 8'h60;
                    4'd2 : o_bits = 8'h60;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h60;
                    4'd6 : o_bits = 8'h60;
                    4'd7 : o_bits = 8'h60;
                    4'd8 : o_bits = 8'h60;
                    4'd9 : o_bits = 8'h60;
                    4'd10: o_bits = 8'h7E;
                    default: o_bits = 8'h00;
                endcase
            end

            // M
            8'h4D: begin
                case (i_row)
                    4'd1 : o_bits = 8'h63;
                    4'd2 : o_bits = 8'h77;
                    4'd3 : o_bits = 8'h7F;
                    4'd4 : o_bits = 8'h7F;
                    4'd5 : o_bits = 8'h6B;
                    4'd6 : o_bits = 8'h63;
                    4'd7 : o_bits = 8'h63;
                    4'd8 : o_bits = 8'h63;
                    4'd9 : o_bits = 8'h63;
                    4'd10: o_bits = 8'h63;
                    default: o_bits = 8'h00;
                endcase
            end

            // N
            8'h4E: begin
                case (i_row)
                    4'd1 : o_bits = 8'h66;
                    4'd2 : o_bits = 8'h76;
                    4'd3 : o_bits = 8'h7E;
                    4'd4 : o_bits = 8'h7E;
                    4'd5 : o_bits = 8'h6E;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h66;
                    default: o_bits = 8'h00;
                endcase
            end

            // O
            8'h4F: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // P
            8'h50: begin
                case (i_row)
                    4'd1 : o_bits = 8'h7C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h7C;
                    4'd6 : o_bits = 8'h60;
                    4'd7 : o_bits = 8'h60;
                    4'd8 : o_bits = 8'h60;
                    4'd9 : o_bits = 8'h60;
                    4'd10: o_bits = 8'h60;
                    default: o_bits = 8'h00;
                endcase
            end

            // Q
            8'h51: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h6E;
                    4'd9 : o_bits = 8'h3C;
                    4'd10: o_bits = 8'h0E;
                    default: o_bits = 8'h00;
                endcase
            end

            // R
            8'h52: begin
                case (i_row)
                    4'd1 : o_bits = 8'h7C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h7C;
                    4'd6 : o_bits = 8'h6C;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h66;
                    default: o_bits = 8'h00;
                endcase
            end

            // S
            8'h53: begin
                case (i_row)
                    4'd1 : o_bits = 8'h3C;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h60;
                    4'd4 : o_bits = 8'h60;
                    4'd5 : o_bits = 8'h3C;
                    4'd6 : o_bits = 8'h06;
                    4'd7 : o_bits = 8'h06;
                    4'd8 : o_bits = 8'h06;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // T
            8'h54: begin
                case (i_row)
                    4'd1 : o_bits = 8'h7E;
                    4'd2 : o_bits = 8'h5A;
                    4'd3 : o_bits = 8'h18;
                    4'd4 : o_bits = 8'h18;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // U
            8'h55: begin
                case (i_row)
                    4'd1 : o_bits = 8'h66;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h66;
                    4'd5 : o_bits = 8'h66;
                    4'd6 : o_bits = 8'h66;
                    4'd7 : o_bits = 8'h66;
                    4'd8 : o_bits = 8'h66;
                    4'd9 : o_bits = 8'h66;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            // W
            8'h57: begin
                case (i_row)
                    4'd1 : o_bits = 8'h63;
                    4'd2 : o_bits = 8'h63;
                    4'd3 : o_bits = 8'h63;
                    4'd4 : o_bits = 8'h63;
                    4'd5 : o_bits = 8'h6B;
                    4'd6 : o_bits = 8'h7F;
                    4'd7 : o_bits = 8'h7F;
                    4'd8 : o_bits = 8'h77;
                    4'd9 : o_bits = 8'h63;
                    4'd10: o_bits = 8'h63;
                    default: o_bits = 8'h00;
                endcase
            end

            // Y
            8'h59: begin
                case (i_row)
                    4'd1 : o_bits = 8'h66;
                    4'd2 : o_bits = 8'h66;
                    4'd3 : o_bits = 8'h66;
                    4'd4 : o_bits = 8'h3C;
                    4'd5 : o_bits = 8'h18;
                    4'd6 : o_bits = 8'h18;
                    4'd7 : o_bits = 8'h18;
                    4'd8 : o_bits = 8'h18;
                    4'd9 : o_bits = 8'h18;
                    4'd10: o_bits = 8'h3C;
                    default: o_bits = 8'h00;
                endcase
            end

            default: begin
                o_bits = 8'h00;
            end
        endcase
    end

endmodule