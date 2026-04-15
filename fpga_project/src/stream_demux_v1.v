`timescale 1ns / 1ps

/*********************************************************************************
* Module       : stream_demux_v1
* Description  :
*   将单路 32-bit RX streaming 数据按类型拆成：
*     1) 视频流 -> RX_VIDEO_FIFO
*     2) 用户/控制流 -> RX_CTRL_FIFO
*
* Type rule:
*   - [31:27] == 5'b00000 : video symbol
*   - others              : ctrl/user word
*
* Notes:
*   1) 本模块只做分流，不做进一步协议解析
*   2) 若目标 FIFO 满，则当前字丢弃，并拉高对应 overflow sticky
*********************************************************************************/

module stream_demux_v1
(
    input               i_clk,
    input               i_rst_n,

    // 单路 RX streaming 输入
    input      [31:0]   i_rx_data,
    input               i_rx_valid,

    // 视频 FIFO 输出
    output reg [31:0]   o_video_fifo_din,
    output reg          o_video_fifo_wr_en,
    input               i_video_fifo_full,

    // 控制 FIFO 输出
    output reg [31:0]   o_ctrl_fifo_din,
    output reg          o_ctrl_fifo_wr_en,
    input               i_ctrl_fifo_full,

    // sticky debug
    output reg          o_video_overflow_sticky,
    output reg          o_ctrl_overflow_sticky,

    output reg          o_dbg_is_video,
    output reg          o_dbg_is_ctrl
);

    wire [4:0] w_type_tag;
    assign w_type_tag = i_rx_data[31:27];

    wire w_is_video;
    wire w_is_ctrl;

    assign w_is_video = (w_type_tag == 5'b00000);
    assign w_is_ctrl  = ~w_is_video;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_video_fifo_din         <= 32'd0;
            o_video_fifo_wr_en       <= 1'b0;

            o_ctrl_fifo_din          <= 32'd0;
            o_ctrl_fifo_wr_en        <= 1'b0;

            o_video_overflow_sticky  <= 1'b0;
            o_ctrl_overflow_sticky   <= 1'b0;

            o_dbg_is_video           <= 1'b0;
            o_dbg_is_ctrl            <= 1'b0;
        end
        else begin
            o_video_fifo_wr_en <= 1'b0;
            o_ctrl_fifo_wr_en  <= 1'b0;

            o_dbg_is_video     <= 1'b0;
            o_dbg_is_ctrl      <= 1'b0;

            if (i_rx_valid) begin
                if (w_is_video) begin
                    o_dbg_is_video <= 1'b1;

                    if (!i_video_fifo_full) begin
                        o_video_fifo_din   <= i_rx_data;
                        o_video_fifo_wr_en <= 1'b1;
                    end
                    else begin
                        o_video_overflow_sticky <= 1'b1;
                    end
                end
                else begin
                    o_dbg_is_ctrl <= 1'b1;

                    if (!i_ctrl_fifo_full) begin
                        o_ctrl_fifo_din   <= i_rx_data;
                        o_ctrl_fifo_wr_en <= 1'b1;
                    end
                    else begin
                        o_ctrl_overflow_sticky <= 1'b1;
                    end
                end
            end
        end
    end

endmodule