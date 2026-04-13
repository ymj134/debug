`timescale 1ns / 1ps

/*********************************************************************************
* Module       : tx_rgb888_packer_v1_0
* Version      : v1.0
* Description  :
*   把 RGB888 像素流打包成 32bit word 流。
*
* Packing rule :
*   4 pixels -> 3 words
*
*   P0 = {R0,G0,B0}
*   P1 = {R1,G1,B1}
*   P2 = {R2,G2,B2}
*   P3 = {R3,G3,B3}
*
*   W0 = {R0,G0,B0,R1}
*   W1 = {G1,B1,R2,G2}
*   W2 = {B2,R3,G3,B3}
*
* Notes :
*   1) 假设一帧 active pixel 总数能被 4 整除。
*   2) o_word_sof 只会打在该帧第一个输出 word 上。
*   3) o_word_eof 只会打在该帧最后一个输出 word 上。
*   4) 若 i_pix_sof / i_pix_eof 落在非预期位置，会拉高 o_align_err_sticky。
*********************************************************************************/

module tx_rgb888_packer_v1_0
(
    input               i_clk,
    input               i_rst_n,

    input               i_pix_valid,
    input       [23:0]  i_pix_data,   // {R,G,B}
    input               i_pix_sof,    // first active pixel of frame
    input               i_pix_eof,    // last active pixel of frame

    output  reg         o_word_valid,
    output  reg [31:0]  o_word_data,
    output  reg         o_word_sof,
    output  reg         o_word_eof,

    output  reg         o_align_err_sticky
);

    // leftover byte count:
    // 0 : no leftover
    // 3 : store {R,G,B}
    // 2 : store {G,B}
    // 1 : store {B}
    reg [1:0]  r_left_cnt;
    reg [23:0] r_left_bytes;

    reg        r_pending_sof;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_left_cnt          <= 2'd0;
            r_left_bytes        <= 24'd0;
            r_pending_sof       <= 1'b0;

            o_word_valid        <= 1'b0;
            o_word_data         <= 32'd0;
            o_word_sof          <= 1'b0;
            o_word_eof          <= 1'b0;
            o_align_err_sticky  <= 1'b0;
        end
        else begin
            o_word_valid <= 1'b0;
            o_word_sof   <= 1'b0;
            o_word_eof   <= 1'b0;

            if (i_pix_valid) begin
                // SOF 应该出现在新的 4-pixel group 起点
                if (i_pix_sof) begin
                    if (r_left_cnt != 2'd0) begin
                        o_align_err_sticky <= 1'b1;
                    end
                    r_pending_sof <= 1'b1;
                end

                case (r_left_cnt)
                    2'd0: begin
                        // 收第1个像素，暂不出 word
                        r_left_bytes <= i_pix_data;   // {R,G,B}
                        r_left_cnt   <= 2'd3;

                        // 如果 EOF 落在这里，说明帧像素数不是 4 的整数倍
                        if (i_pix_eof)
                            o_align_err_sticky <= 1'b1;
                    end

                    2'd3: begin
                        // 有 {R0,G0,B0}，再来 P1={R1,G1,B1}
                        // 输出 W0={R0,G0,B0,R1}
                        o_word_valid <= 1'b1;
                        o_word_data  <= {r_left_bytes[23:0], i_pix_data[23:16]};
                        o_word_sof   <= r_pending_sof;
                        o_word_eof   <= 1'b0;

                        r_pending_sof <= 1'b0;

                        // 剩下 {G1,B1}
                        r_left_bytes <= {8'd0, i_pix_data[15:0]};
                        r_left_cnt   <= 2'd2;

                        if (i_pix_eof)
                            o_align_err_sticky <= 1'b1;
                    end

                    2'd2: begin
                        // 有 {G1,B1}，再来 P2={R2,G2,B2}
                        // 输出 W1={G1,B1,R2,G2}
                        o_word_valid <= 1'b1;
                        o_word_data  <= {r_left_bytes[15:0], i_pix_data[23:8]};
                        o_word_sof   <= 1'b0;
                        o_word_eof   <= 1'b0;

                        // 剩下 {B2}
                        r_left_bytes <= {16'd0, i_pix_data[7:0]};
                        r_left_cnt   <= 2'd1;

                        if (i_pix_eof)
                            o_align_err_sticky <= 1'b1;
                    end

                    2'd1: begin
                        // 有 {B2}，再来 P3={R3,G3,B3}
                        // 输出 W2={B2,R3,G3,B3}
                        o_word_valid <= 1'b1;
                        o_word_data  <= {r_left_bytes[7:0], i_pix_data[23:0]};
                        o_word_sof   <= 1'b0;
                        o_word_eof   <= i_pix_eof;   // 正常情况下 EOF 应该落在这里

                        r_left_bytes <= 24'd0;
                        r_left_cnt   <= 2'd0;

                        if (!i_pix_eof) begin
                            // 正常中间 group，没问题
                        end
                    end

                    default: begin
                        r_left_cnt         <= 2'd0;
                        r_left_bytes       <= 24'd0;
                        r_pending_sof      <= 1'b0;
                        o_align_err_sticky <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule