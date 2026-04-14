`timescale 1 ns / 1 ps

/*********************************************************************************
* Module       : proto_video_rx_depacketizer_v1_0
* Version      : v1.2a
* Description  :
*   VIDEO-only 协议解包器（带 DROP_TO_END 重同步）
*
*   输入：
*     - 直接来自 RoraLink Framing 的 user_rx_* 接口
*
*   输出：
*     - 输出 36bit word 流到 rx_word_fifo
*     - 36bit 格式：
*         [31:0] = packed word
*         [32]   = word_sof
*         [33]   = word_eof
*         [35:34]= reserved
*
* Notes :
*   1) 当前版本仍为 streaming parser：在 VIDEO_PAYLOAD 包内部，payload word 会边收边转发。
*   2) CRC32 在包尾校验完成后仅用于统计/标记，不会回滚已经输出的 payload。
*   3) 新增 S_DROP_TO_END：
*      - 一旦当前包头/长度/格式等判定失败，不立刻把下一个 word 当新包头
*      - 而是持续丢弃直到遇到本包的 i_user_rx_last
*   4) 修正：
*      - S_WAIT_PAYLD 中如果本拍因 fifo_full 进入 DROP_TO_END，不再继续推进 payload 计数/状态
*********************************************************************************/

module proto_video_rx_depacketizer_v1_0
#(
    parameter CHANNEL_ID      = 8'd0,   // VIDEO_MAIN
    parameter PIX_FMT         = 8'h01,  // 0x01 = RGB888

    parameter TYPE_VIDEO_FS   = 8'h01,
    parameter TYPE_VIDEO_PAY  = 8'h11,
    parameter TYPE_VIDEO_FE   = 8'h21
)
(
    input               i_clk,
    input               i_rst_n,

    // RoraLink Framing RX interface
    input      [31:0]   i_user_rx_data,
    input               i_user_rx_valid,
    input               i_user_rx_last,

    // output word fifo
    output reg [35:0]   o_word_fifo_din,
    output reg          o_word_fifo_wr_en,
    input               i_word_fifo_full,

    // debug
    output reg [15:0]   o_dbg_frame_id,
    output reg [15:0]   o_dbg_frag_id,
    output reg [15:0]   o_dbg_frag_total,
    output reg [7:0]    o_dbg_seq,
    output reg [7:0]    o_dbg_pkt_type,
    output reg          o_dbg_hdr_crc_ok,
    output reg          o_dbg_crc32_ok,
    output reg [3:0]    o_dbg_state,
    output reg          o_dbg_err_sticky
);

    //--------------------------------------------------------------------------
    // 0) state
    //--------------------------------------------------------------------------
    localparam [3:0]
        S_WAIT_HDR0    = 4'd0,
        S_WAIT_HDR1    = 4'd1,
        S_WAIT_SUB0    = 4'd2,
        S_WAIT_SUB1    = 4'd3,
        S_WAIT_PAYLD   = 4'd4,
        S_WAIT_CRC     = 4'd5,
        S_DROP_TO_END  = 4'd6;

    reg [3:0] r_state;

    //--------------------------------------------------------------------------
    // 1) packet fields
    //--------------------------------------------------------------------------
    reg [15:0] r_magic;
    reg [7:0]  r_type;
    reg [7:0]  r_channel;
    reg [15:0] r_payload_len;
    reg [7:0]  r_seq;
    reg [7:0]  r_hdr_crc_rx;

    reg [15:0] r_frame_id;
    reg [15:0] r_frag_id;
    reg [15:0] r_frag_total;
    reg [7:0]  r_flags;
    reg [7:0]  r_pix_fmt;

    reg [15:0] r_payload_words_target;
    reg [15:0] r_payload_words_rcvd;

    reg        r_header_valid;
    reg        r_drop_payload;

    //--------------------------------------------------------------------------
    // 2) frame tracking
    //--------------------------------------------------------------------------
    reg        r_frame_active;
    reg [15:0] r_active_frame_id;
    reg [15:0] r_expected_frag_id;
    reg        r_pending_frame_sof;

    //--------------------------------------------------------------------------
    // 3) sticky error bits
    //--------------------------------------------------------------------------
    reg r_err_magic;
    reg r_err_channel;
    reg r_err_type;
    reg r_err_len;
    reg r_err_pixfmt;
    reg r_err_frag;
    reg r_err_unexpected_last;
    reg r_err_missing_last;
    reg r_err_fifo_overflow;
    reg r_err_crc32;

    //--------------------------------------------------------------------------
    // 4) CRC
    //--------------------------------------------------------------------------
    reg [31:0] r_crc32_reg;

    //--------------------------------------------------------------------------
    // 5) CRC8 helper
    //--------------------------------------------------------------------------
    function [7:0] f_crc8_byte;
        input [7:0] crc_in;
        input [7:0] data_in;
        integer i;
        reg [7:0] crc;
        begin
            crc = crc_in ^ data_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[7])
                    crc = {crc[6:0], 1'b0} ^ 8'h07;
                else
                    crc = {crc[6:0], 1'b0};
            end
            f_crc8_byte = crc;
        end
    endfunction

    function [7:0] f_header_crc8;
        input [15:0] magic;
        input [7:0]  type_f;
        input [7:0]  channel_f;
        input [15:0] payload_len_f;
        input [7:0]  seq_f;
        reg   [7:0]  crc;
        begin
            crc = 8'h00;
            crc = f_crc8_byte(crc, magic[15:8]);
            crc = f_crc8_byte(crc, magic[7:0]);
            crc = f_crc8_byte(crc, type_f);
            crc = f_crc8_byte(crc, channel_f);
            crc = f_crc8_byte(crc, payload_len_f[15:8]);
            crc = f_crc8_byte(crc, payload_len_f[7:0]);
            crc = f_crc8_byte(crc, seq_f);
            f_header_crc8 = crc;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 6) CRC32 helper
    //--------------------------------------------------------------------------
    function [31:0] f_crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        integer i;
        reg [31:0] crc;
        begin
            crc = crc_in ^ {24'd0, data_in};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[0])
                    crc = (crc >> 1) ^ 32'hEDB88320;
                else
                    crc = (crc >> 1);
            end
            f_crc32_byte = crc;
        end
    endfunction

    function [31:0] f_crc32_word;
        input [31:0] crc_in;
        input [31:0] word_in;
        reg [31:0] crc;
        begin
            crc = crc_in;
            crc = f_crc32_byte(crc, word_in[7:0]);
            crc = f_crc32_byte(crc, word_in[15:8]);
            crc = f_crc32_byte(crc, word_in[23:16]);
            crc = f_crc32_byte(crc, word_in[31:24]);
            f_crc32_word = crc;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 7) 当前 header 的组合 CRC8
    //--------------------------------------------------------------------------
    wire [7:0] w_hdr_crc_calc;
    assign w_hdr_crc_calc = f_header_crc8(
        r_magic,
        r_type,
        r_channel,
        r_payload_len,
        r_seq
    );

    wire w_crc32_ok;
    assign w_crc32_ok = (i_user_rx_data == ~r_crc32_reg);

    //--------------------------------------------------------------------------
    // 8) 当前包出错时，统一的“进入丢包到包尾”动作
    //--------------------------------------------------------------------------
    task t_enter_drop_to_end;
        begin
            o_dbg_err_sticky <= 1'b1;
            r_header_valid   <= 1'b0;
            r_drop_payload   <= 1'b1;
            r_state          <= S_DROP_TO_END;
        end
    endtask

    //--------------------------------------------------------------------------
    // 9) 合法包时清错误 sticky
    //--------------------------------------------------------------------------
    task t_clear_error_sticky_on_good_packet;
        begin
            o_dbg_err_sticky      <= 1'b0;

            r_err_magic           <= 1'b0;
            r_err_channel         <= 1'b0;
            r_err_type            <= 1'b0;
            r_err_len             <= 1'b0;
            r_err_pixfmt          <= 1'b0;
            r_err_frag            <= 1'b0;
            r_err_unexpected_last <= 1'b0;
            r_err_missing_last    <= 1'b0;
            r_err_fifo_overflow   <= 1'b0;
            r_err_crc32           <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // 10) main
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                <= S_WAIT_HDR0;

            r_magic                <= 16'd0;
            r_type                 <= 8'd0;
            r_channel              <= 8'd0;
            r_payload_len          <= 16'd0;
            r_seq                  <= 8'd0;
            r_hdr_crc_rx           <= 8'd0;

            r_frame_id             <= 16'd0;
            r_frag_id              <= 16'd0;
            r_frag_total           <= 16'd0;
            r_flags                <= 8'd0;
            r_pix_fmt              <= 8'd0;

            r_payload_words_target <= 16'd0;
            r_payload_words_rcvd   <= 16'd0;

            r_header_valid         <= 1'b0;
            r_drop_payload         <= 1'b0;

            r_frame_active         <= 1'b0;
            r_active_frame_id      <= 16'd0;
            r_expected_frag_id     <= 16'd0;
            r_pending_frame_sof    <= 1'b0;

            r_err_magic            <= 1'b0;
            r_err_channel          <= 1'b0;
            r_err_type             <= 1'b0;
            r_err_len              <= 1'b0;
            r_err_pixfmt           <= 1'b0;
            r_err_frag             <= 1'b0;
            r_err_unexpected_last  <= 1'b0;
            r_err_missing_last     <= 1'b0;
            r_err_fifo_overflow    <= 1'b0;
            r_err_crc32            <= 1'b0;

            r_crc32_reg            <= 32'hFFFF_FFFF;

            o_word_fifo_din        <= 36'd0;
            o_word_fifo_wr_en      <= 1'b0;

            o_dbg_frame_id         <= 16'd0;
            o_dbg_frag_id          <= 16'd0;
            o_dbg_frag_total       <= 16'd0;
            o_dbg_seq              <= 8'd0;
            o_dbg_pkt_type         <= 8'd0;
            o_dbg_hdr_crc_ok       <= 1'b0;
            o_dbg_crc32_ok         <= 1'b0;
            o_dbg_state            <= S_WAIT_HDR0;
            o_dbg_err_sticky       <= 1'b0;
        end
        else begin
            o_word_fifo_wr_en <= 1'b0;
            o_dbg_state       <= r_state;

            case (r_state)
                //------------------------------------------------------------------
                // HDR0
                //------------------------------------------------------------------
                S_WAIT_HDR0: begin
                    if (i_user_rx_valid) begin
                        // 新包开始，先清上一包调试结果
                        o_dbg_hdr_crc_ok <= 1'b0;
                        o_dbg_crc32_ok   <= 1'b0;

                        r_crc32_reg      <= f_crc32_word(32'hFFFF_FFFF, i_user_rx_data);

                        r_magic          <= i_user_rx_data[15:0];
                        r_type           <= i_user_rx_data[23:16];
                        r_channel        <= i_user_rx_data[31:24];

                        r_header_valid   <= 1'b0;
                        r_drop_payload   <= 1'b0;

                        if (i_user_rx_last) begin
                            r_err_unexpected_last <= 1'b1;
                            o_dbg_err_sticky      <= 1'b1;
                            r_state               <= S_WAIT_HDR0;
                        end
                        else begin
                            r_state <= S_WAIT_HDR1;
                        end
                    end
                end

                //------------------------------------------------------------------
                // HDR1
                //------------------------------------------------------------------
                S_WAIT_HDR1: begin
                    if (i_user_rx_valid) begin
                        r_crc32_reg    <= f_crc32_word(r_crc32_reg, i_user_rx_data);

                        r_payload_len  <= i_user_rx_data[15:0];
                        r_seq          <= i_user_rx_data[23:16];
                        r_hdr_crc_rx   <= i_user_rx_data[31:24];

                        o_dbg_seq      <= i_user_rx_data[23:16];
                        o_dbg_pkt_type <= r_type;

                        if (i_user_rx_last) begin
                            r_err_unexpected_last <= 1'b1;
                            o_dbg_err_sticky      <= 1'b1;
                            r_state               <= S_WAIT_HDR0;
                        end
                        else begin
                            r_state <= S_WAIT_SUB0;
                        end
                    end
                end

                //------------------------------------------------------------------
                // SUB0
                //------------------------------------------------------------------
                S_WAIT_SUB0: begin
                    if (i_user_rx_valid) begin
                        r_crc32_reg    <= f_crc32_word(r_crc32_reg, i_user_rx_data);

                        r_frame_id     <= i_user_rx_data[15:0];
                        r_frag_id      <= i_user_rx_data[31:16];

                        o_dbg_frame_id <= i_user_rx_data[15:0];
                        o_dbg_frag_id  <= i_user_rx_data[31:16];

                        if (i_user_rx_last) begin
                            r_err_unexpected_last <= 1'b1;
                            o_dbg_err_sticky      <= 1'b1;
                            r_state               <= S_WAIT_HDR0;
                        end
                        else begin
                            r_state <= S_WAIT_SUB1;
                        end
                    end
                end

                //------------------------------------------------------------------
                // SUB1
                //------------------------------------------------------------------
                S_WAIT_SUB1: begin
                    if (i_user_rx_valid) begin
                        r_crc32_reg      <= f_crc32_word(r_crc32_reg, i_user_rx_data);

                        r_frag_total     <= i_user_rx_data[15:0];
                        r_flags          <= i_user_rx_data[23:16];
                        r_pix_fmt        <= i_user_rx_data[31:24];

                        o_dbg_frag_total <= i_user_rx_data[15:0];
                        o_dbg_hdr_crc_ok <= (w_hdr_crc_calc == r_hdr_crc_rx);

                        r_header_valid   <= 1'b1;
                        r_drop_payload   <= 1'b0;

                        if (r_magic != 16'h5AA5) begin
                            r_err_magic <= 1'b1;
                            t_enter_drop_to_end();
                        end
                        else if (r_channel != CHANNEL_ID) begin
                            r_err_channel <= 1'b1;
                            t_enter_drop_to_end();
                        end
                        else if ((r_type != TYPE_VIDEO_FS) &&
                                 (r_type != TYPE_VIDEO_PAY) &&
                                 (r_type != TYPE_VIDEO_FE)) begin
                            r_err_type <= 1'b1;
                            t_enter_drop_to_end();
                        end
                        else if (w_hdr_crc_calc != r_hdr_crc_rx) begin
                            t_enter_drop_to_end();
                        end
                        else if (i_user_rx_data[31:24] != PIX_FMT) begin
                            r_err_pixfmt <= 1'b1;
                            t_enter_drop_to_end();
                        end
                        else begin
                            if (r_payload_len < 16'd8) begin
                                r_err_len <= 1'b1;
                                t_enter_drop_to_end();
                            end
                            else if (r_type == TYPE_VIDEO_PAY) begin
                                if (((r_payload_len - 16'd8) < 16'd4) ||
                                    (((r_payload_len - 16'd8) & 16'h0003) != 16'd0)) begin
                                    r_err_len <= 1'b1;
                                    t_enter_drop_to_end();
                                end
                                else begin
                                    r_payload_words_target <= (r_payload_len - 16'd8) >> 2;
                                    r_payload_words_rcvd   <= 16'd0;

                                    if (i_user_rx_last) begin
                                        r_err_unexpected_last <= 1'b1;
                                        o_dbg_err_sticky      <= 1'b1;
                                        r_state               <= S_WAIT_HDR0;
                                    end
                                    else begin
                                        r_state <= S_WAIT_PAYLD;
                                    end
                                end
                            end
                            else begin
                                // FRAME_START / FRAME_END：payload_len 必须正好是 8
                                if (r_payload_len != 16'd8) begin
                                    r_err_len <= 1'b1;
                                    t_enter_drop_to_end();
                                end
                                else begin
                                    r_payload_words_target <= 16'd0;
                                    r_payload_words_rcvd   <= 16'd0;

                                    if (i_user_rx_last) begin
                                        r_err_unexpected_last <= 1'b1;
                                        o_dbg_err_sticky      <= 1'b1;
                                        r_state               <= S_WAIT_HDR0;
                                    end
                                    else begin
                                        r_state <= S_WAIT_CRC;
                                    end
                                end
                            end
                        end
                    end
                end

                //------------------------------------------------------------------
                // PAYLOAD
                //------------------------------------------------------------------
                S_WAIT_PAYLD: begin
                    if (i_user_rx_valid) begin
                        // payload 中间不该出现 last，last 只该在 CRC 那个 word
                        if (i_user_rx_last) begin
                            r_err_unexpected_last <= 1'b1;
                            o_dbg_err_sticky      <= 1'b1;
                            r_state               <= S_WAIT_HDR0;
                        end
                        else begin
                            r_crc32_reg <= f_crc32_word(r_crc32_reg, i_user_rx_data);

                            if (r_header_valid && !r_drop_payload) begin
                                if (i_word_fifo_full) begin
                                    r_err_fifo_overflow <= 1'b1;
                                    t_enter_drop_to_end();
                                end
                                else begin
                                    o_word_fifo_wr_en      <= 1'b1;
                                    o_word_fifo_din[31:0]  <= i_user_rx_data;
                                    o_word_fifo_din[35:34] <= 2'b00;

                                    // SOF：收到合法 FRAME_START 后，本帧首个 payload word
                                    if (r_pending_frame_sof && (r_payload_words_rcvd == 16'd0)) begin
                                        o_word_fifo_din[32] <= 1'b1;
                                        r_pending_frame_sof <= 1'b0;
                                    end
                                    else begin
                                        o_word_fifo_din[32] <= 1'b0;
                                    end

                                    // EOF：最后一片最后一个 payload word
                                    if ((r_frag_id == (r_frag_total - 16'd1)) &&
                                        (r_payload_words_rcvd == (r_payload_words_target - 16'd1))) begin
                                        o_word_fifo_din[33] <= 1'b1;
                                    end
                                    else begin
                                        o_word_fifo_din[33] <= 1'b0;
                                    end

                                    // 只有本拍真正写成功了，才推进 payload 计数/状态
                                    if (r_payload_words_rcvd == (r_payload_words_target - 16'd1)) begin
                                        r_payload_words_rcvd <= 16'd0;
                                        r_state              <= S_WAIT_CRC;
                                    end
                                    else begin
                                        r_payload_words_rcvd <= r_payload_words_rcvd + 16'd1;
                                    end
                                end
                            end
                        end
                    end
                end

                //------------------------------------------------------------------
                // CRC word / packet end
                //------------------------------------------------------------------
                S_WAIT_CRC: begin
                    if (i_user_rx_valid) begin
                        o_dbg_crc32_ok <= w_crc32_ok;

                        if (!i_user_rx_last) begin
                            r_err_missing_last <= 1'b1;
                            o_dbg_err_sticky   <= 1'b1;
                            r_state            <= S_DROP_TO_END;
                        end
                        else if (w_crc32_ok && r_header_valid) begin
                            t_clear_error_sticky_on_good_packet();

                            if (r_type == TYPE_VIDEO_FS) begin
                                if (r_frame_active) begin
                                    r_err_frag       <= 1'b1;
                                    o_dbg_err_sticky <= 1'b1;
                                end

                                r_frame_active      <= 1'b1;
                                r_active_frame_id   <= r_frame_id;
                                r_expected_frag_id  <= 16'd0;
                                r_pending_frame_sof <= 1'b1;
                            end
                            else if (r_type == TYPE_VIDEO_PAY) begin
                                if (!r_frame_active) begin
                                    r_err_frag       <= 1'b1;
                                    o_dbg_err_sticky <= 1'b1;
                                end
                                else begin
                                    if (r_frame_id != r_active_frame_id) begin
                                        r_err_frag       <= 1'b1;
                                        o_dbg_err_sticky <= 1'b1;
                                    end

                                    if (r_frag_id != r_expected_frag_id) begin
                                        r_err_frag       <= 1'b1;
                                        o_dbg_err_sticky <= 1'b1;
                                    end

                                    r_expected_frag_id <= r_frag_id + 16'd1;
                                end
                            end
                            else if (r_type == TYPE_VIDEO_FE) begin
                                if (!r_frame_active) begin
                                    r_err_frag       <= 1'b1;
                                    o_dbg_err_sticky <= 1'b1;
                                end
                                else begin
                                    if (r_frame_id != r_active_frame_id) begin
                                        r_err_frag       <= 1'b1;
                                        o_dbg_err_sticky <= 1'b1;
                                    end

                                    if (r_frag_id != (r_frag_total - 16'd1)) begin
                                        r_err_frag       <= 1'b1;
                                        o_dbg_err_sticky <= 1'b1;
                                    end

                                    r_frame_active <= 1'b0;
                                end
                            end

                            r_state <= S_WAIT_HDR0;
                        end
                        else begin
                            r_err_crc32      <= 1'b1;
                            o_dbg_err_sticky <= 1'b1;
                            r_state          <= S_WAIT_HDR0; // CRC word 本身已经是包尾
                        end
                    end
                end

                //------------------------------------------------------------------
                // 当前包坏了：一直丢到包尾
                //------------------------------------------------------------------
                S_DROP_TO_END: begin
                    if (i_user_rx_valid && i_user_rx_last) begin
                        r_state <= S_WAIT_HDR0;
                    end
                end

                default: begin
                    r_state <= S_WAIT_HDR0;
                    o_dbg_err_sticky <= 1'b1;
                end
            endcase
        end
    end

endmodule