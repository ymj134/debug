`timescale 1ns / 1ps

/*********************************************************************************
* Module       : proto_video_tx_packetizer_lite_v1
* Version      : v1.0
* Description  :
*   适配 RoraLink frame mode 的最小协议 TX packetizer
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
*   说明：
*     1) 不再使用自定义 magic / payload_len / CRC32
*     2) 包边界交给 RoraLink frame mode
*     3) 发送前仍保留 Rnum 门控，避免 PAY 包中途断流
*     4) 每个包之间插固定 gap，放松 FE -> FS 等短包边界
*********************************************************************************/

module proto_video_tx_packetizer_lite_v1
#(
    parameter ACTIVE_W              = 1920,
    parameter ACTIVE_H              = 1080,
    parameter PAYLOAD_WORDS         = 256,      // 每个 PAY 包携带的 payload word 数
    parameter TYPE_VIDEO_FS         = 8'h01,
    parameter TYPE_VIDEO_PAY        = 8'h11,
    parameter TYPE_VIDEO_FE         = 8'h21,
    parameter PAYLOAD_MARGIN_WORDS  = 13'd64,
    parameter PKT_GAP_CYCLES        = 8'd4      // 先默认 4 拍，更稳
)
(
    input               i_clk,
    input               i_rst_n,

    // input word FIFO (FWFT / Show-Ahead)
    input               i_word_fifo_empty,
    input      [35:0]   i_word_fifo_dout,
    input      [12:0]   i_word_fifo_rnum,
    output reg          o_word_fifo_rd_en,

    // RoraLink frame-mode TX interface
    input               i_user_tx_ready,
    output reg [31:0]   o_user_tx_data,
    output reg          o_user_tx_valid,
    output reg          o_user_tx_last,
    output reg [3:0]    o_user_tx_strb,

    // debug
    output reg [15:0]   o_dbg_frame_id,
    output reg [15:0]   o_dbg_frag_id,
    output reg [15:0]   o_dbg_frag_total,
    output reg [7:0]    o_dbg_seq,
    output reg [7:0]    o_dbg_pkt_type,
    output reg [3:0]    o_dbg_state,
    output reg          o_dbg_err_sticky
);

    //--------------------------------------------------------------------------
    // 0) Local parameters
    //--------------------------------------------------------------------------
    localparam integer WORDS_PER_FRAME         = (ACTIVE_W * ACTIVE_H * 3) / 4;
    localparam integer FRAG_TOTAL              = WORDS_PER_FRAME / PAYLOAD_WORDS;
    localparam integer PAYLOAD_START_THRESHOLD = PAYLOAD_WORDS + PAYLOAD_MARGIN_WORDS;

    localparam [1:0] PKT_FRAME_START = 2'd0;
    localparam [1:0] PKT_VIDEO_PAY   = 2'd1;
    localparam [1:0] PKT_FRAME_END   = 2'd2;

    localparam [3:0]
        S_WAIT_SOF         = 4'd0,
        S_WAIT_PAYLOAD_RDY = 4'd1,
        S_SEND_W0          = 4'd2,
        S_SEND_W1          = 4'd3,
        S_SEND_PAYLOAD     = 4'd4,
        S_PKT_GAP          = 4'd5;

    localparam [1:0]
        GAP_TO_WAIT_SOF         = 2'd0,
        GAP_TO_WAIT_PAYLOAD_RDY = 2'd1,
        GAP_TO_SEND_PREPARED    = 2'd2;

    //--------------------------------------------------------------------------
    // 1) Registers
    //--------------------------------------------------------------------------
    reg [3:0]  r_state;

    reg [1:0]  r_pkt_kind;
    reg [15:0] r_frame_id;
    reg [15:0] r_frag_id;
    reg [7:0]  r_seq;

    reg [15:0] r_payload_words_target;
    reg [15:0] r_payload_words_sent;

    reg [31:0] r_w0;
    reg [31:0] r_w1;

    reg [7:0]  r_gap_cnt;
    reg [1:0]  r_gap_next_action;

    //--------------------------------------------------------------------------
    // 2) FIFO marker aliases
    //--------------------------------------------------------------------------
    wire [31:0] fifo_word = i_word_fifo_dout[31:0];
    wire        fifo_sof  = i_word_fifo_dout[32];
    wire        fifo_eof  = i_word_fifo_dout[33];

    //--------------------------------------------------------------------------
    // 3) TX mux
    //--------------------------------------------------------------------------
    reg [31:0] tx_word_mux;
    reg        tx_valid_mux;
    reg        tx_last_mux;

    wire tx_fire = tx_valid_mux & i_user_tx_ready;

    always @(*) begin
        tx_word_mux  = 32'd0;
        tx_valid_mux = 1'b0;
        tx_last_mux  = 1'b0;

        case (r_state)
            S_SEND_W0: begin
                tx_word_mux  = r_w0;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b0;
            end

            S_SEND_W1: begin
                tx_word_mux  = r_w1;
                tx_valid_mux = 1'b1;
                tx_last_mux  = (r_pkt_kind != PKT_VIDEO_PAY);
            end

            S_SEND_PAYLOAD: begin
                tx_word_mux  = fifo_word;
                tx_valid_mux = ~i_word_fifo_empty;
                tx_last_mux  = (r_payload_words_sent == (r_payload_words_target - 16'd1));
            end

            default: begin
                tx_word_mux  = 32'd0;
                tx_valid_mux = 1'b0;
                tx_last_mux  = 1'b0;
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // 4) Packet builder
    //--------------------------------------------------------------------------
    task t_prepare_packet;
        input [1:0]  pkt_kind;
        input [15:0] frame_id_in;
        input [15:0] frag_id_in;
        input [7:0]  seq_in;
        reg   [7:0]  type_local;
        begin
            case (pkt_kind)
                PKT_FRAME_START: begin
                    type_local          = TYPE_VIDEO_FS;
                    r_w0                <= {type_local, seq_in, frame_id_in};
                    r_w1                <= {FRAG_TOTAL[15:0], 16'h0000};
                    r_payload_words_target <= 16'd0;
                end

                PKT_VIDEO_PAY: begin
                    type_local          = TYPE_VIDEO_PAY;
                    r_w0                <= {type_local, seq_in, frame_id_in};
                    r_w1                <= {frag_id_in, 16'h0000};
                    r_payload_words_target <= PAYLOAD_WORDS[15:0];
                end

                default: begin
                    type_local          = TYPE_VIDEO_FE;
                    r_w0                <= {type_local, seq_in, frame_id_in};
                    r_w1                <= {FRAG_TOTAL[15:0], 16'h0000};
                    r_payload_words_target <= 16'd0;
                end
            endcase

            r_pkt_kind           <= pkt_kind;
            r_payload_words_sent <= 16'd0;

            o_dbg_frame_id       <= frame_id_in;
            o_dbg_frag_id        <= frag_id_in;
            o_dbg_frag_total     <= FRAG_TOTAL[15:0];
            o_dbg_seq            <= seq_in;
            o_dbg_pkt_type       <= type_local;
        end
    endtask

    //--------------------------------------------------------------------------
    // 5) Enter gap helper
    //--------------------------------------------------------------------------
    task t_enter_gap;
        input [1:0] next_action;
        begin
            r_gap_cnt         <= (PKT_GAP_CYCLES > 0) ? (PKT_GAP_CYCLES - 1) : 0;
            r_gap_next_action <= next_action;
            r_state           <= S_PKT_GAP;
        end
    endtask

    //--------------------------------------------------------------------------
    // 6) Main FSM
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                <= S_WAIT_SOF;

            r_pkt_kind             <= PKT_FRAME_START;
            r_frame_id             <= 16'd0;
            r_frag_id              <= 16'd0;
            r_seq                  <= 8'd0;

            r_payload_words_target <= 16'd0;
            r_payload_words_sent   <= 16'd0;

            r_w0                   <= 32'd0;
            r_w1                   <= 32'd0;

            r_gap_cnt              <= 8'd0;
            r_gap_next_action      <= GAP_TO_WAIT_SOF;

            o_word_fifo_rd_en      <= 1'b0;

            o_user_tx_data         <= 32'd0;
            o_user_tx_valid        <= 1'b0;
            o_user_tx_last         <= 1'b0;
            o_user_tx_strb         <= 4'hF;

            o_dbg_frame_id         <= 16'd0;
            o_dbg_frag_id          <= 16'd0;
            o_dbg_frag_total       <= FRAG_TOTAL[15:0];
            o_dbg_seq              <= 8'd0;
            o_dbg_pkt_type         <= 8'd0;
            o_dbg_state            <= S_WAIT_SOF;
            o_dbg_err_sticky       <= 1'b0;
        end
        else begin
            o_word_fifo_rd_en <= 1'b0;

            o_user_tx_data   <= tx_word_mux;
            o_user_tx_valid  <= tx_valid_mux;
            o_user_tx_last   <= tx_last_mux;
            o_user_tx_strb   <= 4'hF;

            o_dbg_state      <= r_state;

            case (r_state)
                // --------------------------------------------------------------
                // 等待新一帧的 SOF word
                // --------------------------------------------------------------
                S_WAIT_SOF: begin
                    if (!i_word_fifo_empty) begin
                        if (fifo_sof) begin
                            t_prepare_packet(PKT_FRAME_START, r_frame_id, 16'd0, r_seq);
                            r_frag_id <= 16'd0;
                            r_state   <= S_SEND_W0;
                        end
                        else begin
                            // 没遇到帧首前，丢弃杂数据
                            o_dbg_err_sticky  <= 1'b1;
                            o_word_fifo_rd_en <= 1'b1;
                        end
                    end
                end

                // --------------------------------------------------------------
                // 等待 FIFO 累积到足够多的 payload 数据，再启动一个 PAY 包
                // --------------------------------------------------------------
                S_WAIT_PAYLOAD_RDY: begin
                    if (i_word_fifo_rnum >= PAYLOAD_START_THRESHOLD[12:0]) begin
                        t_prepare_packet(PKT_VIDEO_PAY, r_frame_id, r_frag_id, r_seq);
                        r_state <= S_SEND_W0;
                    end
                end

                S_SEND_W0: begin
                    if (tx_fire) begin
                        r_state <= S_SEND_W1;
                    end
                end

                S_SEND_W1: begin
                    if (tx_fire) begin
                        if (r_pkt_kind == PKT_VIDEO_PAY)
                            r_state <= S_SEND_PAYLOAD;
                        else begin
                            case (r_pkt_kind)
                                PKT_FRAME_START: begin
                                    r_seq <= r_seq + 8'd1;
                                    t_enter_gap(GAP_TO_WAIT_PAYLOAD_RDY);
                                end

                                default: begin
                                    // FE
                                    r_seq      <= r_seq + 8'd1;
                                    r_frame_id <= r_frame_id + 16'd1;
                                    t_enter_gap(GAP_TO_WAIT_SOF);
                                end
                            endcase
                        end
                    end
                end

                S_SEND_PAYLOAD: begin
                    if (tx_fire) begin
                        // 标记检查
                        if ((r_frag_id == 16'd0) && (r_payload_words_sent == 16'd0)) begin
                            if (!fifo_sof)
                                o_dbg_err_sticky <= 1'b1;
                        end
                        else begin
                            if (fifo_sof)
                                o_dbg_err_sticky <= 1'b1;
                        end

                        if ((r_frag_id == (FRAG_TOTAL[15:0] - 16'd1)) &&
                            (r_payload_words_sent == (r_payload_words_target - 16'd1))) begin
                            if (!fifo_eof)
                                o_dbg_err_sticky <= 1'b1;
                        end
                        else begin
                            if (fifo_eof)
                                o_dbg_err_sticky <= 1'b1;
                        end

                        o_word_fifo_rd_en <= 1'b1;

                        if (r_payload_words_sent == (r_payload_words_target - 16'd1)) begin
                            r_payload_words_sent <= 16'd0;

                            if (r_frag_id == (FRAG_TOTAL[15:0] - 16'd1)) begin
                                // 最后一片 PAY 发完，准备 FE
                                r_seq <= r_seq + 8'd1;
                                t_prepare_packet(PKT_FRAME_END, r_frame_id, r_frag_id, r_seq + 8'd1);
                                t_enter_gap(GAP_TO_SEND_PREPARED);
                            end
                            else begin
                                // 下一片 PAY
                                r_frag_id <= r_frag_id + 16'd1;
                                r_seq     <= r_seq + 8'd1;
                                t_enter_gap(GAP_TO_WAIT_PAYLOAD_RDY);
                            end
                        end
                        else begin
                            r_payload_words_sent <= r_payload_words_sent + 16'd1;
                        end
                    end
                end

                // --------------------------------------------------------------
                // 包间 gap
                // --------------------------------------------------------------
                S_PKT_GAP: begin
                    if (r_gap_cnt != 0) begin
                        r_gap_cnt <= r_gap_cnt - 8'd1;
                    end
                    else begin
                        case (r_gap_next_action)
                            GAP_TO_WAIT_SOF: begin
                                r_state <= S_WAIT_SOF;
                            end

                            GAP_TO_WAIT_PAYLOAD_RDY: begin
                                r_state <= S_WAIT_PAYLOAD_RDY;
                            end

                            GAP_TO_SEND_PREPARED: begin
                                r_state <= S_SEND_W0;
                            end

                            default: begin
                                r_state <= S_WAIT_SOF;
                            end
                        endcase
                    end
                end

                default: begin
                    r_state <= S_WAIT_SOF;
                    o_dbg_err_sticky <= 1'b1;
                end
            endcase
        end
    end

endmodule