`timescale 1ns / 1ps

/*********************************************************************************
* Module       : video_symbol_packer_v1
* Description  :
*   将每个 pixel 时刻的完整视频符号打成 32bit 数据流
*
* Packed format:
*   [23:0]  RGB
*   [24]    DE
*   [25]    HS
*   [26]    VS
*   [31:27] reserved = 0
*
* Notes:
*   1) 这是 full-timing streaming 方案，不再区分 active-only
*   2) blanking 区也会持续输出 word_valid=1
*   3) 如果下游 FIFO 满，本拍数据会丢失，并拉高 overflow sticky
*********************************************************************************/

module video_symbol_packer_v1
(
    input               i_clk,
    input               i_rst_n,

    input               i_enable,

    input               i_vs,
    input               i_hs,
    input               i_de,
    input      [23:0]   i_rgb,

    // 下游是否能接收，一般接 ~tx_fifo_full
    input               i_word_ready,

    output     [31:0]   o_word_data,
    output              o_word_valid,

    output reg          o_overflow_sticky
);

    // 每个像素时刻打成一个 32bit word
    assign o_word_data  = {5'b00000, i_vs, i_hs, i_de, i_rgb};

    // full timing streaming：enable 后每拍都有效
    assign o_word_valid = i_enable;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_overflow_sticky <= 1'b0;
        end
        else begin
            // 上游无法停，只能记录丢数
            if (i_enable && !i_word_ready)
                o_overflow_sticky <= 1'b1;
        end
    end

endmodule