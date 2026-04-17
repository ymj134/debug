`timescale 1ns / 1ps

/*********************************************************************************
* Module       : osd_menu_overlay_v1
* Description  :
*   菜单型 OSD 叠加模块
*
* Functions:
*   1) i_osd_enable=0 时，o_rgb 直接透传 i_base_rgb
*   2) i_osd_enable=1 时，在活动区中间叠加菜单框
*   3) 菜单内容固定为 6 行：
*        COLORBAR
*        NETGRID
*        GRAY
*        BWSQUARE
*        RED
*        GREEN
*   4) i_menu_index 对应行高亮
*
* Notes:
*   1) 依赖 font_rom_8x16_v1
*   2) bit[7] 是字体最左像素，bit[0] 是最右像素
*********************************************************************************/

module osd_menu_overlay_v1
#(
    parameter integer ACTIVE_H_START = 260,
    parameter integer ACTIVE_V_START = 25,
    parameter integer ACTIVE_W       = 1280,
    parameter integer ACTIVE_H       = 720,

    parameter integer BOX_W          = 360,
    parameter integer BOX_H          = 200,

    parameter integer BORDER_W       = 2,

    parameter integer FONT_W         = 8,
    parameter integer FONT_H         = 16,

    parameter integer MENU_ROWS      = 6,
    parameter integer MENU_COLS      = 10,

    parameter integer TEXT_X0        = 24,
    parameter integer TEXT_Y0        = 20,
    parameter integer ROW_H          = 24,
    parameter integer FONT_Y_IN_ROW  = 4,

    parameter [23:0] BOX_BG_COLOR    = 24'h101020,
    parameter [23:0] BORDER_COLOR    = 24'hC0C0C0,
    parameter [23:0] TEXT_COLOR      = 24'hFFFFFF,
    parameter [23:0] SEL_BG_COLOR    = 24'h2A4BFF,
    parameter [23:0] SEL_TEXT_COLOR  = 24'hFFFFFF
)
(
    input               i_clk,
    input               i_rst_n,

    input               i_osd_enable,
    input       [2:0]   i_menu_index,

    input       [15:0]  i_h_cnt,
    input       [15:0]  i_v_cnt,
    input               i_de,

    input       [23:0]  i_base_rgb,

    output reg  [23:0]  o_rgb,
    output reg          o_in_box
);

    localparam integer BOX_X = ACTIVE_H_START + ((ACTIVE_W - BOX_W) / 2);
    localparam integer BOX_Y = ACTIVE_V_START + ((ACTIVE_H - BOX_H) / 2);

    localparam integer ROW_BG_X0 = 12;
    localparam integer ROW_BG_W  = BOX_W - 24;

    //--------------------------------------------------------------------------
    // menu char function
    //--------------------------------------------------------------------------
    function [7:0] fn_menu_char;
        input [2:0] line_idx;
        input [3:0] col_idx;
        begin
            fn_menu_char = " ";

            case (line_idx)
                3'd0: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "C";
                        4'd1: fn_menu_char = "O";
                        4'd2: fn_menu_char = "L";
                        4'd3: fn_menu_char = "O";
                        4'd4: fn_menu_char = "R";
                        4'd5: fn_menu_char = "B";
                        4'd6: fn_menu_char = "A";
                        4'd7: fn_menu_char = "R";
                        default: fn_menu_char = " ";
                    endcase
                end

                3'd1: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "N";
                        4'd1: fn_menu_char = "E";
                        4'd2: fn_menu_char = "T";
                        4'd3: fn_menu_char = "G";
                        4'd4: fn_menu_char = "R";
                        4'd5: fn_menu_char = "I";
                        4'd6: fn_menu_char = "D";
                        default: fn_menu_char = " ";
                    endcase
                end

                3'd2: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "G";
                        4'd1: fn_menu_char = "R";
                        4'd2: fn_menu_char = "A";
                        4'd3: fn_menu_char = "Y";
                        default: fn_menu_char = " ";
                    endcase
                end

                3'd3: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "B";
                        4'd1: fn_menu_char = "W";
                        4'd2: fn_menu_char = "S";
                        4'd3: fn_menu_char = "Q";
                        4'd4: fn_menu_char = "U";
                        4'd5: fn_menu_char = "A";
                        4'd6: fn_menu_char = "R";
                        4'd7: fn_menu_char = "E";
                        default: fn_menu_char = " ";
                    endcase
                end

                3'd4: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "R";
                        4'd1: fn_menu_char = "E";
                        4'd2: fn_menu_char = "D";
                        default: fn_menu_char = " ";
                    endcase
                end

                3'd5: begin
                    case (col_idx)
                        4'd0: fn_menu_char = "G";
                        4'd1: fn_menu_char = "R";
                        4'd2: fn_menu_char = "E";
                        4'd3: fn_menu_char = "E";
                        4'd4: fn_menu_char = "N";
                        default: fn_menu_char = " ";
                    endcase
                end

                default: begin
                    fn_menu_char = " ";
                end
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // internal regs
    //--------------------------------------------------------------------------
    reg         r_in_box;
    reg         r_in_border;

    reg         r_row_valid;
    reg         r_row_selected;
    reg         r_in_row_band;

    reg  [2:0]  r_row_idx;
    reg  [7:0]  r_row_local_y;

    reg         r_in_text;
    reg  [3:0]  r_char_col;
    reg  [2:0]  r_font_col;
    reg  [3:0]  r_font_row;
    reg  [7:0]  r_char_code;

    reg  [23:0] r_rgb;

    reg  [15:0] r_rel_x;
    reg  [15:0] r_rel_y;
    reg  [15:0] r_text_rel_x;

    wire [7:0]  w_font_bits;
    wire        w_char_on;

    assign w_char_on = r_in_text ? w_font_bits[7 - r_font_col] : 1'b0;

    font_rom_8x16_v1 u_font_rom_8x16_v1
    (
        .i_char (r_char_code),
        .i_row  (r_font_row),
        .o_bits (w_font_bits)
    );

    //--------------------------------------------------------------------------
    // geometry / selector decode
    //--------------------------------------------------------------------------
    always @(*) begin
        r_in_box       = 1'b0;
        r_in_border    = 1'b0;

        r_row_valid    = 1'b0;
        r_row_selected = 1'b0;
        r_in_row_band  = 1'b0;

        r_row_idx      = 3'd0;
        r_row_local_y  = 8'd0;

        r_in_text      = 1'b0;
        r_char_col     = 4'd0;
        r_font_col     = 3'd0;
        r_font_row     = 4'd0;
        r_char_code    = " ";

        r_rel_x        = 16'd0;
        r_rel_y        = 16'd0;
        r_text_rel_x   = 16'd0;

        if (i_osd_enable && i_de &&
            (i_h_cnt >= BOX_X) && (i_h_cnt < (BOX_X + BOX_W)) &&
            (i_v_cnt >= BOX_Y) && (i_v_cnt < (BOX_Y + BOX_H))) begin

            r_in_box = 1'b1;
            r_rel_x  = i_h_cnt - BOX_X;
            r_rel_y  = i_v_cnt - BOX_Y;

            // border
            if ((r_rel_x < BORDER_W) || (r_rel_x >= (BOX_W - BORDER_W)) ||
                (r_rel_y < BORDER_W) || (r_rel_y >= (BOX_H - BORDER_W))) begin
                r_in_border = 1'b1;
            end

            // row decode
            if ((r_rel_y >= TEXT_Y0) && (r_rel_y < (TEXT_Y0 + ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd0;
                r_row_local_y = r_rel_y - TEXT_Y0;
            end
            else if ((r_rel_y >= (TEXT_Y0 + ROW_H)) && (r_rel_y < (TEXT_Y0 + 2*ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd1;
                r_row_local_y = r_rel_y - (TEXT_Y0 + ROW_H);
            end
            else if ((r_rel_y >= (TEXT_Y0 + 2*ROW_H)) && (r_rel_y < (TEXT_Y0 + 3*ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd2;
                r_row_local_y = r_rel_y - (TEXT_Y0 + 2*ROW_H);
            end
            else if ((r_rel_y >= (TEXT_Y0 + 3*ROW_H)) && (r_rel_y < (TEXT_Y0 + 4*ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd3;
                r_row_local_y = r_rel_y - (TEXT_Y0 + 3*ROW_H);
            end
            else if ((r_rel_y >= (TEXT_Y0 + 4*ROW_H)) && (r_rel_y < (TEXT_Y0 + 5*ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd4;
                r_row_local_y = r_rel_y - (TEXT_Y0 + 4*ROW_H);
            end
            else if ((r_rel_y >= (TEXT_Y0 + 5*ROW_H)) && (r_rel_y < (TEXT_Y0 + 6*ROW_H))) begin
                r_row_valid   = 1'b1;
                r_row_idx     = 3'd5;
                r_row_local_y = r_rel_y - (TEXT_Y0 + 5*ROW_H);
            end

            r_row_selected = r_row_valid && (r_row_idx == i_menu_index);

            // row highlight band
            if (r_row_valid &&
                (r_rel_x >= ROW_BG_X0) &&
                (r_rel_x < (ROW_BG_X0 + ROW_BG_W))) begin
                r_in_row_band = 1'b1;
            end

            // text area
            if (r_row_valid &&
                (r_rel_x >= TEXT_X0) &&
                (r_rel_x < (TEXT_X0 + MENU_COLS*FONT_W)) &&
                (r_row_local_y >= FONT_Y_IN_ROW) &&
                (r_row_local_y < (FONT_Y_IN_ROW + FONT_H))) begin

                r_in_text    = 1'b1;
                r_text_rel_x = r_rel_x - TEXT_X0;

                r_char_col   = r_text_rel_x[15:3];    // /8
                r_font_col   = r_text_rel_x[2:0];
                r_font_row   = r_row_local_y - FONT_Y_IN_ROW;
                r_char_code  = fn_menu_char(r_row_idx, r_text_rel_x[15:3]);
            end
        end
    end

    //--------------------------------------------------------------------------
    // final rgb select
    //--------------------------------------------------------------------------
    always @(*) begin
        r_rgb   = i_base_rgb;
        o_in_box = 1'b0;

        if (r_in_box) begin
            o_in_box = 1'b1;

            if (r_in_border) begin
                r_rgb = BORDER_COLOR;
            end
            else if (w_char_on) begin
                r_rgb = r_row_selected ? SEL_TEXT_COLOR : TEXT_COLOR;
            end
            else if (r_in_row_band && r_row_selected) begin
                r_rgb = SEL_BG_COLOR;
            end
            else begin
                r_rgb = BOX_BG_COLOR;
            end
        end
    end

    //--------------------------------------------------------------------------
    // output register
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rgb <= 24'h000000;
        end
        else begin
            o_rgb <= r_rgb;
        end
    end

endmodule