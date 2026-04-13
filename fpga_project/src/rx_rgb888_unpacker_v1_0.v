`timescale 1ns / 1ps

/*********************************************************************************
* Module       : rx_rgb888_unpacker_v1_0
* Version      : v1.0
* Description  :
*   把 32bit packed word 流还原成 RGB888 像素流。
*
* Input word format :
*   i_fifo_dout[31:0]  = packed word
*   i_fifo_dout[32]    = word_sof
*   i_fifo_dout[33]    = word_eof
*   i_fifo_dout[35:34] = reserved
*
* Notes :
*   1) 推荐接在“sys_clk -> pixel_clk 的 word async fifo”后面。
*   2) 模块内部是“4B输入 / 3B输出”的字节流解包器。
*   3) o_pix_valid 只在真正输出一个像素的那个时钟拍拉高。
*   4) 若输入格式异常，会拉高 o_format_err_sticky。
*********************************************************************************/

module rx_rgb888_unpacker_v1_0
(
    input               i_clk,
    input               i_rst_n,

    // 来自 word FIFO（FWFT / Show-Ahead）
    input       [35:0]  i_fifo_dout,
    input               i_fifo_empty,
    output  reg         o_fifo_rd_en,

    // 下游像素消费者请求（比如显示侧 active 区、或 pixel fifo 非满）
    input               i_pix_ready,

    output  reg         o_pix_valid,
    output  reg [23:0]  o_pix_data,   // {R,G,B}
    output  reg         o_pix_sof,
    output  reg         o_pix_eof,

    output  reg         o_format_err_sticky
);

    // 有效字节缓冲：
    // 低 byte 区域存放有效字节，且“最老字节”位于有效区的高位
    // byte_cnt 范围 0~8 即可
    reg [63:0] r_byte_buf;
    reg [3:0]  r_byte_cnt;

    reg        r_pending_sof;
    reg        r_pending_eof;
    reg        r_frame_in_progress;

    reg [63:0] v_buf;
    reg [3:0]  v_cnt;
    reg [23:0] v_pix;

    function [63:0] f_low_mask_bytes;
        input [3:0] n;
        begin
            case (n)
                4'd0: f_low_mask_bytes = 64'h0000_0000_0000_0000;
                4'd1: f_low_mask_bytes = 64'h0000_0000_0000_00FF;
                4'd2: f_low_mask_bytes = 64'h0000_0000_0000_FFFF;
                4'd3: f_low_mask_bytes = 64'h0000_0000_00FF_FFFF;
                4'd4: f_low_mask_bytes = 64'h0000_0000_FFFF_FFFF;
                4'd5: f_low_mask_bytes = 64'h0000_00FF_FFFF_FFFF;
                4'd6: f_low_mask_bytes = 64'h0000_FFFF_FFFF_FFFF;
                4'd7: f_low_mask_bytes = 64'h00FF_FFFF_FFFF_FFFF;
                default: f_low_mask_bytes = 64'hFFFF_FFFF_FFFF_FFFF;
            endcase
        end
    endfunction

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_byte_buf         <= 64'd0;
            r_byte_cnt         <= 4'd0;
            r_pending_sof      <= 1'b0;
            r_pending_eof      <= 1'b0;
            r_frame_in_progress<= 1'b0;

            o_fifo_rd_en       <= 1'b0;
            o_pix_valid        <= 1'b0;
            o_pix_data         <= 24'd0;
            o_pix_sof          <= 1'b0;
            o_pix_eof          <= 1'b0;
            o_format_err_sticky<= 1'b0;
        end
        else begin
            o_fifo_rd_en <= 1'b0;
            o_pix_valid  <= 1'b0;
            o_pix_sof    <= 1'b0;
            o_pix_eof    <= 1'b0;

            v_buf = r_byte_buf;
            v_cnt = r_byte_cnt;

            // ------------------------------------------------------------
            // Step 1: 尽量从 word FIFO 预取 1 个 word
            // 策略：当缓存字节数 <= 4 且 FIFO 非空时，读 1 个 word
            // ------------------------------------------------------------
            if ((!i_fifo_empty) && (v_cnt <= 4)) begin
                o_fifo_rd_en <= 1'b1;

                // 读进来 4 个新字节，拼到“有效区尾部”
                v_buf = (v_buf << 32) | i_fifo_dout[31:0];
                v_cnt = v_cnt + 4'd4;

                // SOF / EOF 语义检查
                if (i_fifo_dout[32]) begin
                    if (r_frame_in_progress)
                        o_format_err_sticky <= 1'b1;
                    r_pending_sof       <= 1'b1;
                    r_frame_in_progress <= 1'b1;
                end

                if (i_fifo_dout[33]) begin
                    if (!r_frame_in_progress)
                        o_format_err_sticky <= 1'b1;
                    if (r_pending_eof)
                        o_format_err_sticky <= 1'b1;
                    r_pending_eof <= 1'b1;
                end
            end

            // ------------------------------------------------------------
            // Step 2: 若下游要像素，且缓存里已有至少 3 个字节，就输出 1 像素
            // ------------------------------------------------------------
            if (i_pix_ready && (v_cnt >= 3)) begin
                v_pix = (v_buf >> ((v_cnt - 3) * 8));

                o_pix_valid <= 1'b1;
                o_pix_data  <= v_pix;
                o_pix_sof   <= r_pending_sof;
                o_pix_eof   <= (r_pending_eof && (v_cnt == 3));

                if (r_pending_sof)
                    r_pending_sof <= 1'b0;

                if (r_pending_eof && (v_cnt == 3)) begin
                    r_pending_eof       <= 1'b0;
                    r_frame_in_progress <= 1'b0;
                end

                v_cnt = v_cnt - 3;
                v_buf = v_buf & f_low_mask_bytes(v_cnt);
            end

            r_byte_buf <= v_buf;
            r_byte_cnt <= v_cnt;
        end
    end

endmodule