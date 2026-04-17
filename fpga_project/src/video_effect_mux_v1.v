`timescale 1ns / 1ps

/*********************************************************************************
* Module       : video_effect_mux_v1
* Description  :
*   在 pixel_clk 域对输入 RGB 做模式选择
*
* Modes:
*   0: 正常透传
*   1: 纯红
*   2: 纯绿
*   3: 纯蓝
*   4: 棋盘格
*   5: 灰阶条
*
* Notes:
*   1) 使用本地显示 timing 坐标 i_h_cnt / i_v_cnt
*   2) 仅在 i_de=1 时输出图像，非有效区输出黑
*********************************************************************************/

module video_effect_mux_v1
#(
    parameter [15:0] ACTIVE_H_START = 16'd260,
    parameter [15:0] ACTIVE_V_START = 16'd25,
    parameter [15:0] ACTIVE_W       = 16'd1280,
    parameter [15:0] ACTIVE_H       = 16'd720,

    parameter [15:0] CHECKER_SIZE   = 16'd64
)
(
    input               i_clk,
    input               i_rst_n,

    input      [2:0]    i_pattern_mode,

    input      [15:0]   i_h_cnt,
    input      [15:0]   i_v_cnt,
    input               i_de,

    input      [23:0]   i_base_rgb,

    output reg [23:0]   o_rgb
);

    wire [15:0] act_x;
    wire [15:0] act_y;

    assign act_x = i_h_cnt - ACTIVE_H_START;
    assign act_y = i_v_cnt - ACTIVE_V_START;

    wire checker_bit;
    assign checker_bit =
        ((act_x / CHECKER_SIZE) ^ (act_y / CHECKER_SIZE)) & 16'd1;

    reg [7:0] gray_val;

    always @(*) begin
        // 灰阶条：按水平坐标分布
        // 1280 >> 5 = 40，取 act_x[10:3] 可以形成比较明显的渐变
        gray_val = act_x[10:3];
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rgb <= 24'h000000;
        end
        else begin
            if (!i_de) begin
                o_rgb <= 24'h000000;
            end
            else begin
                case (i_pattern_mode)
                    3'd0: begin
                        o_rgb <= i_base_rgb;
                    end

                    3'd1: begin
                        o_rgb <= 24'hFF0000;
                    end

                    3'd2: begin
                        o_rgb <= 24'h00FF00;
                    end

                    3'd3: begin
                        o_rgb <= 24'h0000FF;
                    end

                    3'd4: begin
                        o_rgb <= checker_bit ? 24'hFFFFFF : 24'h000000;
                    end

                    3'd5: begin
                        o_rgb <= {gray_val, gray_val, gray_val};
                    end

                    default: begin
                        o_rgb <= i_base_rgb;
                    end
                endcase
            end
        end
    end

endmodule