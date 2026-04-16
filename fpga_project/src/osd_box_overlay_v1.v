`timescale 1ns / 1ps

/*********************************************************************************
* Module       : osd_box_overlay_v1
* Description  :
*   在本地显示 timing 坐标系下，对输入 RGB 做矩形 OSD 叠加
*
* Function:
*   - OSD OFF : 输出透传 base_rgb
*   - OSD ON  : 在屏幕中间矩形区域输出黑色，其余区域透传
*
* Notes:
*   1) 使用的是绝对 timing 计数 tp_h_cnt / tp_v_cnt
*   2) 通过 ACTIVE_H_START / ACTIVE_V_START 折算到 active 区内坐标
*   3) 仅在 i_de=1 的有效区内做叠加
*********************************************************************************/

module osd_box_overlay_v1
#(
    parameter [15:0] ACTIVE_H_START = 16'd260,
    parameter [15:0] ACTIVE_V_START = 16'd25,
    parameter [15:0] ACTIVE_W       = 16'd1280,
    parameter [15:0] ACTIVE_H       = 16'd720,

    parameter [15:0] BOX_W          = 16'd320,
    parameter [15:0] BOX_H          = 16'd120
)
(
    input               i_clk,
    input               i_rst_n,

    input               i_osd_enable,

    input      [15:0]   i_h_cnt,
    input      [15:0]   i_v_cnt,
    input               i_de,

    input      [23:0]   i_base_rgb,

    output reg [23:0]   o_rgb,

    output reg          o_in_box
);

    localparam [15:0] BOX_X_START = (ACTIVE_W - BOX_W) / 2;
    localparam [15:0] BOX_Y_START = (ACTIVE_H - BOX_H) / 2;
    localparam [15:0] BOX_X_END   = BOX_X_START + BOX_W;
    localparam [15:0] BOX_Y_END   = BOX_Y_START + BOX_H;

    wire [15:0] act_x;
    wire [15:0] act_y;

    wire        in_active_area;
    wire        in_box_area;

    assign act_x = i_h_cnt - ACTIVE_H_START;
    assign act_y = i_v_cnt - ACTIVE_V_START;

    assign in_active_area = i_de;
    assign in_box_area    = in_active_area &&
                            (act_x >= BOX_X_START) && (act_x < BOX_X_END) &&
                            (act_y >= BOX_Y_START) && (act_y < BOX_Y_END);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rgb    <= 24'h000000;
            o_in_box <= 1'b0;
        end
        else begin
            o_in_box <= in_box_area;

            if (i_osd_enable && in_box_area)
                o_rgb <= 24'h000000;   // 中间黑块
            else
                o_rgb <= i_base_rgb;
        end
    end

endmodule