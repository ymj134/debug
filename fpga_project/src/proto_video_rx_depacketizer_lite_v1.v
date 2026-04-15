`timescale 1 ns / 1 ps

/*********************************************************************************
* Module       : proto_video_rx_depacketizer_lite_v1
* Version      : v1.0
* Description  :
*   适配 RoraLink frame mode 的最小协议 RX depacketizer
*
*   协议：
*     FS:
*       Word0 = {type=8'h01, seq, frame_id}
*       Word1 = {frag_total, 16'h0000}
*
*     PAY:
*       Word0 = {type=8'h11, seq, frame_id}
*       Word1 = {frag_id, 16'h0000}
*       Word2... = payload words
*
*     FE:
*       Word0 = {type=8'h21, seq, frame_id}
*       Word1 = {frag_total, 16'h0000}
*
* Notes:
*   1) 依赖 RoraLink frame mode 提供包边界；不再使用自定义 magic/len/CRC32。
*   2) o_dbg_hdr_crc_ok 被重定义为“包头有效脉冲”。
*   3) o_dbg_crc32_ok 被重定义为“整包提交成功脉冲”。
*   4) 仍保留 DROP_TO_END，用于坏包时丢到本包结束。
*********************************************************************************/

module proto_video_rx_depacketizer_lite_v1
#(
    parameter TYPE_VIDEO_FS  = 8'h01,
    parameter TYPE_VIDEO_PAY = 8'h11,
    parameter TYPE_VIDEO_FE  = 8'h21
)
(
    input               i_clk,
    input               i_rst_n,

    // RoraLink frame-mode RX interface
    input      [31:0]   i_user_rx_data,
    input               i_user_rx_valid,
    input               i_user_rx_last,

    // output word fifo
    output reg [35:0]   o_word_fifo_din,
    output reg          o_word_fifo_wr_en,
    input               i_word_fifo_full,

    // debug (保持和你现有 top/monitor 兼容)
    output reg [15:0]   o_dbg_frame_id,
    output reg [15:0]   o_dbg_frag_id,
    output reg [15:0]   o_dbg_frag_total,
    output reg [7:0]    o_dbg_seq,
    output reg [7:0]    o_dbg_pkt_type,
    output reg          o_dbg_hdr_crc_ok,   // 这里作为“header accepted pulse”
    output reg          o_dbg_crc32_ok,     // 这里作为“packet commit pulse”
    output reg [3:0]    o_dbg_state,
    output reg          o_dbg_err_sticky
);

    //--------------------------------------------------------------------------
    // 0) state
    //--------------------------------------------------------------------------
    localparam [3:0]
        S_WAIT_W0       = 4'd0,
        S_WAIT_W1       = 4'd1,
        S_WAIT_PAYLOAD  = 4'd2,
        S_DROP_TO_END   = 4'd3;

    reg [3:0] r_state;

    //--------------------------------------------------------------------------
    // 1) current packet header fields
    //--------------------------------------------------------------------------
    reg [7:0]  r_type;
    reg [7:0]  r_seq;
    reg [15:0] r_frame_id;

    reg [15:0] r_word1_hi;          // FS/FE: frag_total, PAY: frag_id

    //--------------------------------------------------------------------------
    // 2) current frame tracking
    //--------------------------------------------------------------------------
    reg        r_frame_active;
    reg [15:0] r_active_frame_id;
    reg [15:0] r_active_frag_total;
    reg [15:0] r_expected_frag_id;
    reg        r_pending_frame_sof;

    // 当前 PAY 包上下文
    reg [15:0] r_pay_frag_id;
    reg [15:0] r_pay_frame_id;

    //--------------------------------------------------------------------------
    // 3) helpers
    //--------------------------------------------------------------------------
    wire [7:0]  w_w0_type     = i_user_rx_data[31:24];
    wire [7:0]  w_w0_seq      = i_user_rx_data[23:16];
    wire [15:0] w_w0_frame_id = i_user_rx_data[15:0];
    wire [15:0] w_w1_hi       = i_user_rx_data[31:16];

    //--------------------------------------------------------------------------
    // 4) main
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state             <= S_WAIT_W0;

            r_type              <= 8'd0;
            r_seq               <= 8'd0;
            r_frame_id          <= 16'd0;
            r_word1_hi          <= 16'd0;

            r_frame_active      <= 1'b0;
            r_active_frame_id   <= 16'd0;
            r_active_frag_total <= 16'd0;
            r_expected_frag_id  <= 16'd0;
            r_pending_frame_sof <= 1'b0;

            r_pay_frag_id       <= 16'd0;
            r_pay_frame_id      <= 16'd0;

            o_word_fifo_din     <= 36'd0;
            o_word_fifo_wr_en   <= 1'b0;

            o_dbg_frame_id      <= 16'd0;
            o_dbg_frag_id       <= 16'd0;
            o_dbg_frag_total    <= 16'd0;
            o_dbg_seq           <= 8'd0;
            o_dbg_pkt_type      <= 8'd0;
            o_dbg_hdr_crc_ok    <= 1'b0;
            o_dbg_crc32_ok      <= 1'b0;
            o_dbg_state         <= S_WAIT_W0;
            o_dbg_err_sticky    <= 1'b0;
        end
        else begin
            o_word_fifo_wr_en <= 1'b0;
            o_dbg_hdr_crc_ok  <= 1'b0;
            o_dbg_crc32_ok    <= 1'b0;
            o_dbg_state       <= r_state;

            case (r_state)
                //------------------------------------------------------------------
                // Word0: {type, seq, frame_id}
                //------------------------------------------------------------------
                S_WAIT_W0: begin
                    if (i_user_rx_valid) begin
                        r_type     <= w_w0_type;
                        r_seq      <= w_w0_seq;
                        r_frame_id <= w_w0_frame_id;

                        o_dbg_pkt_type <= w_w0_type;
                        o_dbg_seq      <= w_w0_seq;
                        o_dbg_frame_id <= w_w0_frame_id;

                        // 一个合法包不可能只有 1 个 word
                        if (i_user_rx_last) begin
                            o_dbg_err_sticky <= 1'b1;
                            r_state          <= S_WAIT_W0;
                        end
                        else begin
                            r_state <= S_WAIT_W1;
                        end
                    end
                end

                //------------------------------------------------------------------
                // Word1:
                //   FS: {frag_total, 16'h0000}
                //   PAY:{frag_id   , 16'h0000}
                //   FE: {frag_total, 16'h0000}
                //------------------------------------------------------------------
                S_WAIT_W1: begin
                    if (i_user_rx_valid) begin
                        r_word1_hi <= w_w1_hi;

                        case (r_type)
                            // ------------------------------------------------------
                            // FS packet: must end at word1
                            // ------------------------------------------------------
                            TYPE_VIDEO_FS: begin
                                o_dbg_frag_total <= w_w1_hi;
                                o_dbg_frag_id    <= 16'd0;
                                o_dbg_hdr_crc_ok <= 1'b1;

                                if (!i_user_rx_last) begin
                                    // FS 不该带额外 payload
                                    o_dbg_err_sticky <= 1'b1;
                                    r_state          <= S_DROP_TO_END;
                                end
                                else begin
                                    // 若上一帧还没正常结束，先记错，但为了 demo 继续覆盖启动新帧
                                    if (r_frame_active)
                                        o_dbg_err_sticky <= 1'b1;

                                    r_frame_active      <= 1'b1;
                                    r_active_frame_id   <= r_frame_id;
                                    r_active_frag_total <= w_w1_hi;
                                    r_expected_frag_id  <= 16'd0;
                                    r_pending_frame_sof <= 1'b1;

                                    o_dbg_crc32_ok <= 1'b1;   // 这里表示 packet commit
                                    r_state        <= S_WAIT_W0;
                                end
                            end

                            // ------------------------------------------------------
                            // FE packet: must end at word1
                            // ------------------------------------------------------
                            TYPE_VIDEO_FE: begin
                                o_dbg_frag_total <= w_w1_hi;
                                o_dbg_frag_id    <= 16'd0;
                                o_dbg_hdr_crc_ok <= 1'b1;

                                if (!i_user_rx_last) begin
                                    o_dbg_err_sticky <= 1'b1;
                                    r_state          <= S_DROP_TO_END;
                                end
                                else begin
                                    // 检查 FE 是否与当前 frame 对得上
                                    if (!r_frame_active)
                                        o_dbg_err_sticky <= 1'b1;
                                    else if (r_frame_id != r_active_frame_id)
                                        o_dbg_err_sticky <= 1'b1;
                                    else if (w_w1_hi != r_active_frag_total)
                                        o_dbg_err_sticky <= 1'b1;
                                    else if (r_expected_frag_id != r_active_frag_total)
                                        o_dbg_err_sticky <= 1'b1;

                                    r_frame_active      <= 1'b0;
                                    r_pending_frame_sof <= 1'b0;

                                    o_dbg_crc32_ok <= 1'b1;   // packet commit
                                    r_state        <= S_WAIT_W0;
                                end
                            end

                            // ------------------------------------------------------
                            // PAY packet: word1 后面必须还有 payload
                            // ------------------------------------------------------
                            TYPE_VIDEO_PAY: begin
                                o_dbg_frag_id    <= w_w1_hi;
                                o_dbg_frag_total <= r_active_frag_total;
                                o_dbg_hdr_crc_ok <= 1'b1;

                                if (i_user_rx_last) begin
                                    // PAY 不可能只有头，没有 payload
                                    o_dbg_err_sticky <= 1'b1;
                                    r_state          <= S_WAIT_W0;
                                end
                                else begin
                                    // 进入 payload 前先做上下文检查
                                    if (!r_frame_active) begin
                                        o_dbg_err_sticky <= 1'b1;
                                        r_state          <= S_DROP_TO_END;
                                    end
                                    else if (r_frame_id != r_active_frame_id) begin
                                        o_dbg_err_sticky <= 1'b1;
                                        r_state          <= S_DROP_TO_END;
                                    end
                                    else if (w_w1_hi != r_expected_frag_id) begin
                                        o_dbg_err_sticky <= 1'b1;
                                        r_state          <= S_DROP_TO_END;
                                    end
                                    else begin
                                        r_pay_frag_id  <= w_w1_hi;
                                        r_pay_frame_id <= r_frame_id;
                                        r_state        <= S_WAIT_PAYLOAD;
                                    end
                                end
                            end

                            // ------------------------------------------------------
                            // unknown type
                            // ------------------------------------------------------
                            default: begin
                                o_dbg_err_sticky <= 1'b1;
                                if (i_user_rx_last)
                                    r_state <= S_WAIT_W0;
                                else
                                    r_state <= S_DROP_TO_END;
                            end
                        endcase
                    end
                end

                //------------------------------------------------------------------
                // PAY payload words: forward to RX word fifo
                //------------------------------------------------------------------
                S_WAIT_PAYLOAD: begin
                    if (i_user_rx_valid) begin
                        if (i_word_fifo_full) begin
                            o_dbg_err_sticky <= 1'b1;

                            if (i_user_rx_last)
                                r_state <= S_WAIT_W0;
                            else
                                r_state <= S_DROP_TO_END;
                        end
                        else begin
                            o_word_fifo_wr_en      <= 1'b1;
                            o_word_fifo_din[31:0]  <= i_user_rx_data;
                            o_word_fifo_din[35:34] <= 2'b00;

                            // SOF：当前 frame 的第一个 PAY 的第一个 payload word
                            if (r_pending_frame_sof) begin
                                o_word_fifo_din[32] <= 1'b1;
                                r_pending_frame_sof <= 1'b0;
                            end
                            else begin
                                o_word_fifo_din[32] <= 1'b0;
                            end

                            // EOF：最后一个 fragment 的最后一个 payload word
                            if ((r_pay_frag_id == (r_active_frag_total - 16'd1)) && i_user_rx_last)
                                o_word_fifo_din[33] <= 1'b1;
                            else
                                o_word_fifo_din[33] <= 1'b0;

                            if (i_user_rx_last) begin
                                r_expected_frag_id <= r_expected_frag_id + 16'd1;
                                o_dbg_crc32_ok     <= 1'b1;   // packet commit
                                r_state            <= S_WAIT_W0;
                            end
                        end
                    end
                end

                //------------------------------------------------------------------
                // Drop current bad packet until this frame ends
                //------------------------------------------------------------------
                S_DROP_TO_END: begin
                    if (i_user_rx_valid && i_user_rx_last) begin
                        r_state <= S_WAIT_W0;
                    end
                end

                default: begin
                    r_state <= S_WAIT_W0;
                    o_dbg_err_sticky <= 1'b1;
                end
            endcase
        end
    end

endmodule