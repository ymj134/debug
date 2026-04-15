`timescale 1ns / 1ps

/*********************************************************************************
* Module       : video_symbol_unpacker_v1
* Description  :
*   将 32bit 视频符号流拆回完整 timing：
*     VS / HS / DE / RGB
*
* Packed format:
*   [23:0]  RGB
*   [24]    DE
*   [25]    HS
*   [26]    VS
*   [31:27] reserved
*
* Notes:
*   1) 适用于 full-timing streaming 方案
*   2) 默认输入 FIFO 为 FWFT / Show-Ahead 模式
*   3) 当 i_video_ready=1 时：
*        - 若 FIFO 非空，则消费一个 symbol，并输出一拍 o_valid=1
*        - 若 FIFO 为空，则记 underflow sticky
*   4) 该模块不做帧重建，不做对齐，只是逐拍还原视频符号
*********************************************************************************/

module video_symbol_unpacker_v1
(
    input               i_clk,
    input               i_rst_n,

    // 来自 RX async FIFO（建议 32-bit，FWFT / Show-Ahead）
    input      [31:0]   i_fifo_dout,
    input               i_fifo_empty,
    output reg          o_fifo_rd_en,

    // 下游是否准备接收当前像素时刻的视频符号
    // 一般直接接 1'b1，或者接显示链的 ready
    input               i_video_ready,

    // 输出恢复后的视频 timing / pixel
    output reg          o_valid,
    output reg          o_vs,
    output reg          o_hs,
    output reg          o_de,
    output reg [23:0]   o_rgb,

    output reg          o_underflow_sticky
);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_fifo_rd_en        <= 1'b0;
            o_valid             <= 1'b0;
            o_vs                <= 1'b0;
            o_hs                <= 1'b0;
            o_de                <= 1'b0;
            o_rgb               <= 24'h000000;
            o_underflow_sticky  <= 1'b0;
        end
        else begin
            // 默认不读、不输出有效
            o_fifo_rd_en <= 1'b0;
            o_valid      <= 1'b0;

            if (i_video_ready) begin
                if (!i_fifo_empty) begin
                    // 当前拍消费一个符号
                    o_fifo_rd_en <= 1'b1;
                    o_valid      <= 1'b1;

                    // 直接拆字段
                    o_rgb <= i_fifo_dout[23:0];
                    o_de  <= i_fifo_dout[24];
                    o_hs  <= i_fifo_dout[25];
                    o_vs  <= i_fifo_dout[26];
                end
                else begin
                    // 需要数据，但 FIFO 空了
                    o_underflow_sticky <= 1'b1;

                    // 输出空白安全值
                    o_valid <= 1'b0;
                    o_rgb   <= 24'h000000;
                    o_de    <= 1'b0;
                    o_hs    <= 1'b0;
                    o_vs    <= 1'b0;
                end
            end
        end
    end

endmodule