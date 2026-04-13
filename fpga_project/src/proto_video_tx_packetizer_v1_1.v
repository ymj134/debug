`timescale 1ns / 1ps

/*********************************************************************************
* Module       : proto_video_tx_packetizer_v1_1
* Version      : v1.1
* Description  :
*   VIDEO-only 协议打包器（带 TX FIFO 读侧余量门控）
*
*   新增逻辑：
*     - 只有当读侧 FIFO 中累积到足够多的 word（Rnum 达阈值）时，
*       才启动一个 VIDEO_PAYLOAD 包
*     - 避免 payload 包发到一半 FIFO 见底，导致 valid 中途断开
*
* FIFO 输入格式：
*   [31:0] = packed word
*   [32]   = sof
*   [33]   = eof
*   [35:34]= reserved
*********************************************************************************/

module proto_video_tx_packetizer_v1_1
#(
    parameter ACTIVE_W        = 1920,
    parameter ACTIVE_H        = 1080,
    parameter PAYLOAD_BYTES   = 1024,     // fixed VIDEO_PAYLOAD payload bytes
    parameter CHANNEL_ID      = 8'd0,     // VIDEO_MAIN
    parameter PIX_FMT         = 8'h01,    // 0x01 = RGB888
    parameter TYPE_VIDEO_FS   = 8'h01,    // VIDEO / FRAME_START
    parameter TYPE_VIDEO_PAY  = 8'h11,    // VIDEO / VIDEO_PAYLOAD
    parameter TYPE_VIDEO_FE   = 8'h21,    // VIDEO / FRAME_END
    parameter PAYLOAD_MARGIN_WORDS = 13'd64
)
(
    input               i_clk,
    input               i_rst_n,

    // input word FIFO (FWFT / Show-Ahead)
    input               i_word_fifo_empty,
    input      [35:0]   i_word_fifo_dout,
    input      [12:0]   i_word_fifo_rnum,
    output reg          o_word_fifo_rd_en,

    // RoraLink Framing TX interface
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
    localparam integer PAYLOAD_WORDS   = PAYLOAD_BYTES / 4;
    localparam integer WORDS_PER_FRAME = (ACTIVE_W * ACTIVE_H * 3) / 4;
    localparam integer FRAG_TOTAL      = WORDS_PER_FRAME / PAYLOAD_WORDS;
    localparam integer PAYLOAD_START_THRESHOLD = PAYLOAD_WORDS + PAYLOAD_MARGIN_WORDS;

    localparam [1:0] PKT_FRAME_START = 2'd0;
    localparam [1:0] PKT_VIDEO_PAY   = 2'd1;
    localparam [1:0] PKT_FRAME_END   = 2'd2;

    localparam [3:0]
        S_WAIT_SOF         = 4'd0,
        S_WAIT_PAYLOAD_RDY = 4'd1,
        S_SEND_HDR0        = 4'd2,
        S_SEND_HDR1        = 4'd3,
        S_SEND_SUB0        = 4'd4,
        S_SEND_SUB1        = 4'd5,
        S_SEND_PAYLOAD     = 4'd6,
        S_SEND_CRC         = 4'd7;

    //--------------------------------------------------------------------------
    // 1) Registers
    //--------------------------------------------------------------------------
    reg [3:0]  r_state;

    reg [1:0]  r_pkt_kind;
    reg [15:0] r_frame_id;
    reg [15:0] r_frag_id;
    reg [7:0]  r_seq;

    reg [15:0] r_payload_len_bytes;
    reg [15:0] r_payload_words_target;
    reg [15:0] r_payload_words_sent;

    reg [31:0] r_hdr_w0;
    reg [31:0] r_hdr_w1;
    reg [31:0] r_sub_w0;
    reg [31:0] r_sub_w1;

    reg [31:0] r_crc32_reg;

    //--------------------------------------------------------------------------
    // 2) FIFO marker aliases
    //--------------------------------------------------------------------------
    wire [31:0] fifo_word = i_word_fifo_dout[31:0];
    wire        fifo_sof  = i_word_fifo_dout[32];
    wire        fifo_eof  = i_word_fifo_dout[33];

    //--------------------------------------------------------------------------
    // 3) Current TX word mux
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
            S_SEND_HDR0: begin
                tx_word_mux  = r_hdr_w0;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b0;
            end

            S_SEND_HDR1: begin
                tx_word_mux  = r_hdr_w1;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b0;
            end

            S_SEND_SUB0: begin
                tx_word_mux  = r_sub_w0;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b0;
            end

            S_SEND_SUB1: begin
                tx_word_mux  = r_sub_w1;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b0;
            end

            S_SEND_PAYLOAD: begin
                tx_word_mux  = fifo_word;
                tx_valid_mux = ~i_word_fifo_empty;
                tx_last_mux  = 1'b0;
            end

            S_SEND_CRC: begin
                tx_word_mux  = ~r_crc32_reg;
                tx_valid_mux = 1'b1;
                tx_last_mux  = 1'b1;
            end

            default: begin
                tx_word_mux  = 32'd0;
                tx_valid_mux = 1'b0;
                tx_last_mux  = 1'b0;
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // 4) CRC8 helper
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
    // 5) CRC32 helper
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
    // 6) Packet builder task
    //--------------------------------------------------------------------------
    task t_prepare_packet;
        input [1:0]  pkt_kind;
        input [15:0] frame_id_in;
        input [15:0] frag_id_in;
        input [7:0]  seq_in;
        reg   [7:0]  type_local;
        reg   [7:0]  flags_local;
        reg   [7:0]  hdr_crc_local;
        reg   [15:0] payload_len_local;
        reg   [15:0] payload_words_local;
        begin
            case (pkt_kind)
                PKT_FRAME_START: begin
                    type_local          = TYPE_VIDEO_FS;
                    flags_local         = 8'h01;
                    payload_len_local   = 16'd8;
                    payload_words_local = 16'd0;
                end

                PKT_VIDEO_PAY: begin
                    type_local          = TYPE_VIDEO_PAY;
                    flags_local         = 8'h00;
                    payload_len_local   = 16'd8 + PAYLOAD_BYTES;
                    payload_words_local = PAYLOAD_WORDS[15:0];
                end

                default: begin
                    type_local          = TYPE_VIDEO_FE;
                    flags_local         = 8'h02;
                    payload_len_local   = 16'd8;
                    payload_words_local = 16'd0;
                end
            endcase

            hdr_crc_local = f_header_crc8(
                16'h5AA5,
                type_local,
                CHANNEL_ID,
                payload_len_local,
                seq_in
            );

            r_hdr_w0               <= {CHANNEL_ID, type_local, 16'h5AA5};
            r_hdr_w1               <= {hdr_crc_local, seq_in, payload_len_local};

            r_sub_w0               <= {frag_id_in, frame_id_in};
            r_sub_w1               <= {PIX_FMT, flags_local, FRAG_TOTAL[15:0]};

            r_pkt_kind             <= pkt_kind;
            r_payload_len_bytes    <= payload_len_local;
            r_payload_words_target <= payload_words_local;
            r_payload_words_sent   <= 16'd0;

            o_dbg_frame_id         <= frame_id_in;
            o_dbg_frag_id          <= frag_id_in;
            o_dbg_frag_total       <= FRAG_TOTAL[15:0];
            o_dbg_seq              <= seq_in;
            o_dbg_pkt_type         <= type_local;
        end
    endtask

    //--------------------------------------------------------------------------
    // 7) Main FSM
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                <= S_WAIT_SOF;

            r_pkt_kind             <= PKT_FRAME_START;
            r_frame_id             <= 16'd0;
            r_frag_id              <= 16'd0;
            r_seq                  <= 8'd0;

            r_payload_len_bytes    <= 16'd0;
            r_payload_words_target <= 16'd0;
            r_payload_words_sent   <= 16'd0;

            r_hdr_w0               <= 32'd0;
            r_hdr_w1               <= 32'd0;
            r_sub_w0               <= 32'd0;
            r_sub_w1               <= 32'd0;

            r_crc32_reg            <= 32'hFFFF_FFFF;

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
                            r_crc32_reg <= 32'hFFFF_FFFF;
                            r_frag_id   <= 16'd0;
                            r_state     <= S_SEND_HDR0;
                        end
                        else begin
                            o_dbg_err_sticky <= 1'b1;
                            o_word_fifo_rd_en <= 1'b1;
                        end
                    end
                end

                // --------------------------------------------------------------
                // 等待 FIFO 里累积到足够多的数据，再启动一个 VIDEO_PAYLOAD 包
                // --------------------------------------------------------------
                S_WAIT_PAYLOAD_RDY: begin
                    if (i_word_fifo_rnum >= PAYLOAD_START_THRESHOLD[12:0]) begin
                        t_prepare_packet(PKT_VIDEO_PAY, r_frame_id, r_frag_id, r_seq);
                        r_crc32_reg <= 32'hFFFF_FFFF;
                        r_state     <= S_SEND_HDR0;
                    end
                end

                S_SEND_HDR0: begin
                    if (tx_fire) begin
                        r_crc32_reg <= f_crc32_word(32'hFFFF_FFFF, r_hdr_w0);
                        r_state     <= S_SEND_HDR1;
                    end
                end

                S_SEND_HDR1: begin
                    if (tx_fire) begin
                        r_crc32_reg <= f_crc32_word(r_crc32_reg, r_hdr_w1);
                        r_state     <= S_SEND_SUB0;
                    end
                end

                S_SEND_SUB0: begin
                    if (tx_fire) begin
                        r_crc32_reg <= f_crc32_word(r_crc32_reg, r_sub_w0);
                        r_state     <= S_SEND_SUB1;
                    end
                end

                S_SEND_SUB1: begin
                    if (tx_fire) begin
                        r_crc32_reg <= f_crc32_word(r_crc32_reg, r_sub_w1);

                        if (r_payload_words_target != 0)
                            r_state <= S_SEND_PAYLOAD;
                        else
                            r_state <= S_SEND_CRC;
                    end
                end

                S_SEND_PAYLOAD: begin
                    if (tx_fire) begin
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
                        r_crc32_reg       <= f_crc32_word(r_crc32_reg, fifo_word);

                        if (r_payload_words_sent == (r_payload_words_target - 16'd1)) begin
                            r_payload_words_sent <= 16'd0;
                            r_state              <= S_SEND_CRC;
                        end
                        else begin
                            r_payload_words_sent <= r_payload_words_sent + 16'd1;
                        end
                    end
                end

                S_SEND_CRC: begin
                    if (tx_fire) begin
                        case (r_pkt_kind)
                            PKT_FRAME_START: begin
                                // 准备进入第 0 个 VIDEO_PAYLOAD，但先等 FIFO 里攒够
                                r_seq   <= r_seq + 8'd1;
                                r_frag_id<= 16'd0;
                                r_state <= S_WAIT_PAYLOAD_RDY;
                            end

                            PKT_VIDEO_PAY: begin
                                if (r_frag_id == (FRAG_TOTAL[15:0] - 16'd1)) begin
                                    // 最后一片发完，进入 FRAME_END
                                    r_seq <= r_seq + 8'd1;
                                    t_prepare_packet(PKT_FRAME_END, r_frame_id, r_frag_id, r_seq + 8'd1);
                                    r_crc32_reg <= 32'hFFFF_FFFF;
                                    r_state <= S_SEND_HDR0;
                                end
                                else begin
                                    // 下一个 VIDEO_PAYLOAD，先攒够 FIFO 再发
                                    r_frag_id <= r_frag_id + 16'd1;
                                    r_seq     <= r_seq + 8'd1;
                                    r_state   <= S_WAIT_PAYLOAD_RDY;
                                end
                            end

                            default: begin
                                // FRAME_END 发完，一帧结束
                                r_seq      <= r_seq + 8'd1;
                                r_frame_id <= r_frame_id + 16'd1;
                                r_state    <= S_WAIT_SOF;
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