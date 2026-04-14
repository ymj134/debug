`timescale 1 ns / 1 ps

/*********************************************************************************
* Module       : rx_frame_monitor_v1_0
* Version      : v1.0
* Description  :
*   基于 RX 侧“已通过 CRC32 的包”做帧级监控。
*
*   约定：
*     i_dbg_rx_pkt_type = 8'h01  -> FRAME_START
*     i_dbg_rx_pkt_type = 8'h11  -> VIDEO_PAYLOAD
*     i_dbg_rx_pkt_type = 8'h21  -> FRAME_END
*
*   仅当 i_dbg_rx_crc32_ok = 1 时，本模块才认为当前包“有效并参与帧级统计”。
*
*   监控内容：
*     1) 是否按 FS -> PAYLOAD... -> FE 闭环
*     2) frag_id 是否从 0 连续递增
*     3) FE 时 frag_id 是否等于 frag_total - 1
*     4) frame_id 是否连续递增
*********************************************************************************/

module rx_frame_monitor_v1_0
(
    input               i_clk,
    input               i_rst_n,

    input       [7:0]   i_dbg_rx_pkt_type,
    input       [7:0]   i_dbg_rx_seq,
    input       [15:0]  i_dbg_rx_frame_id,
    input       [15:0]  i_dbg_rx_frag_id,
    input       [15:0]  i_dbg_rx_frag_total,
    input               i_dbg_rx_crc32_ok,

    output  reg         o_frame_ok_sticky,
    output  reg         o_frame_err_sticky,
    output  reg         o_frame_id_jump_sticky,

    output  reg         o_in_frame,
    output  reg         o_frame_bad,

    output  reg [31:0]  o_good_frame_cnt,
    output  reg [31:0]  o_bad_frame_cnt,

    output  reg [15:0]  o_last_good_frame_id,
    output  reg [15:0]  o_last_bad_frame_id,

    output  reg [7:0]   o_last_good_seq,
    output  reg [7:0]   o_last_bad_seq,

    output  reg [15:0]  o_cur_frame_id,
    output  reg [15:0]  o_expected_frag_id,
    output  reg [15:0]  o_last_seen_frag_id
);

    localparam [7:0] PKT_FS  = 8'h01;
    localparam [7:0] PKT_PAY = 8'h11;
    localparam [7:0] PKT_FE  = 8'h21;

    reg [15:0] r_cur_frag_total;
    reg        r_seen_payload;

    reg        r_last_started_frame_valid;
    reg [15:0] r_last_started_frame_id;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_frame_ok_sticky         <= 1'b0;
            o_frame_err_sticky        <= 1'b0;
            o_frame_id_jump_sticky    <= 1'b0;

            o_in_frame                <= 1'b0;
            o_frame_bad               <= 1'b0;

            o_good_frame_cnt          <= 32'd0;
            o_bad_frame_cnt           <= 32'd0;

            o_last_good_frame_id      <= 16'd0;
            o_last_bad_frame_id       <= 16'd0;

            o_last_good_seq           <= 8'd0;
            o_last_bad_seq            <= 8'd0;

            o_cur_frame_id            <= 16'd0;
            o_expected_frag_id        <= 16'd0;
            o_last_seen_frag_id       <= 16'd0;

            r_cur_frag_total          <= 16'd0;
            r_seen_payload            <= 1'b0;

            r_last_started_frame_valid<= 1'b0;
            r_last_started_frame_id   <= 16'd0;
        end
        else begin
            // 只在“当前包 CRC32 正确”时处理
            if (i_dbg_rx_crc32_ok) begin
                case (i_dbg_rx_pkt_type)

                    // ----------------------------------------------------------
                    // FRAME_START
                    // ----------------------------------------------------------
                    PKT_FS: begin
                        // 若上一帧还没正常结束，就判上一帧为 bad
                        if (o_in_frame) begin
                            o_bad_frame_cnt     <= o_bad_frame_cnt + 32'd1;
                            o_frame_err_sticky  <= 1'b1;
                            o_last_bad_frame_id <= o_cur_frame_id;
                            o_last_bad_seq      <= i_dbg_rx_seq;
                        end

                        // 检查 frame_id 连续性
                        if (r_last_started_frame_valid) begin
                            if (i_dbg_rx_frame_id != (r_last_started_frame_id + 16'd1))
                                o_frame_id_jump_sticky <= 1'b1;
                        end

                        r_last_started_frame_valid <= 1'b1;
                        r_last_started_frame_id    <= i_dbg_rx_frame_id;

                        // 开启新帧
                        o_in_frame         <= 1'b1;
                        o_frame_bad        <= 1'b0;
                        o_cur_frame_id     <= i_dbg_rx_frame_id;
                        o_expected_frag_id <= 16'd0;
                        o_last_seen_frag_id<= 16'd0;

                        r_cur_frag_total   <= i_dbg_rx_frag_total;
                        r_seen_payload     <= 1'b0;
                    end

                    // ----------------------------------------------------------
                    // VIDEO_PAYLOAD
                    // ----------------------------------------------------------
                    PKT_PAY: begin
                        if (!o_in_frame) begin
                            // 没有先看到 FRAME_START 就来了 payload
                            o_bad_frame_cnt     <= o_bad_frame_cnt + 32'd1;
                            o_frame_err_sticky  <= 1'b1;
                            o_last_bad_frame_id <= i_dbg_rx_frame_id;
                            o_last_bad_seq      <= i_dbg_rx_seq;
                        end
                        else begin
                            // 检查 frame_id / frag_total / frag_id
                            if ((i_dbg_rx_frame_id  != o_cur_frame_id) ||
                                (i_dbg_rx_frag_total != r_cur_frag_total) ||
                                (i_dbg_rx_frag_id    != o_expected_frag_id)) begin
                                o_frame_bad         <= 1'b1;
                                o_frame_err_sticky  <= 1'b1;
                                o_last_bad_frame_id <= o_cur_frame_id;
                                o_last_bad_seq      <= i_dbg_rx_seq;
                                o_last_seen_frag_id <= i_dbg_rx_frag_id;
                            end
                            else begin
                                r_seen_payload      <= 1'b1;
                                o_last_seen_frag_id <= i_dbg_rx_frag_id;
                                o_expected_frag_id  <= o_expected_frag_id + 16'd1;
                            end
                        end
                    end

                    // ----------------------------------------------------------
                    // FRAME_END
                    // ----------------------------------------------------------
                    PKT_FE: begin
                        if (!o_in_frame) begin
                            // 没有先看到 FRAME_START 就来了 FRAME_END
                            o_bad_frame_cnt     <= o_bad_frame_cnt + 32'd1;
                            o_frame_err_sticky  <= 1'b1;
                            o_last_bad_frame_id <= i_dbg_rx_frame_id;
                            o_last_bad_seq      <= i_dbg_rx_seq;
                        end
                        else begin
                            // 检查本帧是否完整
                            if (!o_frame_bad &&
                                r_seen_payload &&
                                (i_dbg_rx_frame_id  == o_cur_frame_id) &&
                                (i_dbg_rx_frag_total == r_cur_frag_total) &&
                                (i_dbg_rx_frag_id    == (i_dbg_rx_frag_total - 16'd1)) &&
                                (o_expected_frag_id  == i_dbg_rx_frag_total)) begin

                                o_good_frame_cnt     <= o_good_frame_cnt + 32'd1;
                                o_frame_ok_sticky    <= 1'b1;
                                o_last_good_frame_id <= i_dbg_rx_frame_id;
                                o_last_good_seq      <= i_dbg_rx_seq;
                            end
                            else begin
                                o_bad_frame_cnt      <= o_bad_frame_cnt + 32'd1;
                                o_frame_err_sticky   <= 1'b1;
                                o_last_bad_frame_id  <= o_cur_frame_id;
                                o_last_bad_seq       <= i_dbg_rx_seq;
                            end

                            // 关闭当前帧
                            o_in_frame          <= 1'b0;
                            o_frame_bad         <= 1'b0;
                            o_expected_frag_id  <= 16'd0;
                            o_last_seen_frag_id <= i_dbg_rx_frag_id;

                            r_cur_frag_total    <= 16'd0;
                            r_seen_payload      <= 1'b0;
                        end
                    end

                    // ----------------------------------------------------------
                    // 未知 type
                    // ----------------------------------------------------------
                    default: begin
                        o_frame_err_sticky <= 1'b1;
                        if (o_in_frame)
                            o_frame_bad <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule