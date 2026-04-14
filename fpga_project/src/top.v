`timescale 1ns / 1ps

/*********************************************************************************
* Module       : video_loop_top_v3_0_0
* Version      : v3.0.0
* Description  :
*   1080p60 RGB888 active-only 视频回环 top 框架
*
* Data path:
*   testpattern(pixel_clk)
*     -> tx_rgb888_packer_v1_0
*     -> tx word async fifo (pixel_clk -> sys_clk)
*     -> proto_video_tx_packetizer_v1_0
*     -> SerDes_Top
*     -> proto_video_rx_depacketizer_v1_0
*     -> rx word async fifo (sys_clk -> pixel_clk)
*     -> rx_rgb888_unpacker_v1_0
*     -> HDMI display mux
*
* Notes:
*   1) 当前版本只实现 VIDEO-only。
*   2) USER_CMD / USER_ACK 的接口与仲裁先预留，不接入业务。
*   3) 默认支持“可视化回环图”模式，方便肉眼区分本地与回环。
*********************************************************************************/

module top
#(
    parameter DEBUG_VISUALIZE_RX = 1'b1   // 1: R/B交换+G取反，0: 原样显示RX图像
)
(
    input           osc_clk_i,          // 50M
    input           resetn_i,           // low-active

    output          sfp1_tx_disable_o,
    output          sfp2_tx_disable_o,

    input           rx_i,               // 预留未使用
    output          tx_o,               // 预留未使用

    output [3:0]    test_o,
    output [3:0]    led_o,

    inout           IO_adv7513_scl,
    inout           IO_adv7513_sda,
    output          O_adv7513_clk,
    output          O_adv7513_vs,
    output          O_adv7513_hs,
    output          O_adv7513_de,
    output [23:0]   O_adv7513_data
);

    //==========================================================================
    // 0) 参数
    //==========================================================================
    `define LANE_WIDTH      1
    `define LANE_DATA_WIDTH 32

    localparam DATA_WIDTH      = `LANE_DATA_WIDTH * `LANE_WIDTH;
    localparam STRB_WIDTH      = DATA_WIDTH / 8;
    localparam LANE_WIDTH      = `LANE_WIDTH;
    localparam LANE_DATA_WIDTH = `LANE_DATA_WIDTH;

    localparam [31:0] TOP_VERSION = 32'h3000_0000;

    // 1080p60 timing
    localparam [15:0] C_H_TOTAL  = 16'd2200;
    localparam [15:0] C_H_SYNC   = 16'd44;
    localparam [15:0] C_H_BPORCH = 16'd148;
    localparam [15:0] C_H_RES    = 16'd1920;
    localparam [15:0] C_V_TOTAL  = 16'd1125;
    localparam [15:0] C_V_SYNC   = 16'd5;
    localparam [15:0] C_V_BPORCH = 16'd36;
    localparam [15:0] C_V_RES    = 16'd1080;

    // active 起止
    localparam [15:0] ACT_H_START = C_H_SYNC + C_H_BPORCH;              // 192
    localparam [15:0] ACT_H_END   = C_H_SYNC + C_H_BPORCH + C_H_RES;    // 2112
    localparam [15:0] ACT_V_START = C_V_SYNC + C_V_BPORCH;              // 41
    localparam [15:0] ACT_V_END   = C_V_SYNC + C_V_BPORCH + C_V_RES;    // 1121

    //==========================================================================
    // 1) RoraLink 用户接口（Framing）
    //==========================================================================
    wire [DATA_WIDTH-1:0] user_tx_data;
    wire [STRB_WIDTH-1:0] user_tx_strb;
    wire                  user_tx_valid;
    wire                  user_tx_last;
    wire                  user_tx_ready;

    wire [DATA_WIDTH-1:0] user_rx_data;
    wire [STRB_WIDTH-1:0] user_rx_strb;
    wire                  user_rx_valid;
    wire                  user_rx_last;

    wire                  crc_pass_fail_n;
    wire                  crc_valid;
    wire                  hard_err;
    wire                  soft_err;
    wire                  frame_err;

    wire                  channel_up;
    wire [LANE_WIDTH-1:0] lane_up;

    //==========================================================================
    // 2) 时钟 / 复位 / GT 状态
    //==========================================================================
    wire                  sys_clk/* synthesis syn_keep=1 */;
    wire                  sys_rst;
    wire                  cfg_clk;
    wire                  cfg_pll_lock;
    wire                  cfg_rst;
    wire                  sys_reset_gen;

    wire                  gt_reset;
    wire                  gt_pcs_tx_reset;
    wire                  gt_pcs_rx_reset;

    wire [LANE_WIDTH-1:0] gt_pcs_tx_clk;
    wire [LANE_WIDTH-1:0] gt_pcs_rx_clk;
    wire                  gt_pll_ok;

    wire [LANE_WIDTH-1:0] gt_rx_align_link;
    wire [LANE_WIDTH-1:0] gt_rx_pma_lock;
    wire [LANE_WIDTH-1:0] gt_rx_k_lock;

    wire                  link_reset;
    wire                  sys_reset;

    //==========================================================================
    // 3) pixel / HDMI / 本地测试图
    //==========================================================================
    wire        pixel_clk;
    wire        pixel_clk_lock;
    wire        pixel_rst;
    wire        pixel_rst_n = ~pixel_rst;

    wire [15:0] tp_v_cnt;
    wire [15:0] tp_h_cnt;
    wire        tp_vs;
    wire        tp_hs;
    wire        tp_de;
    wire [7:0]  tp_r;
    wire [7:0]  tp_g;
    wire [7:0]  tp_b;

    reg         tp_vs_d = 1'b0;
    reg  [9:0]  frame_cnt = 10'd0;

    //==========================================================================
    // 4) 本地源 active-only 像素流定义
    //==========================================================================
    wire src_pix_valid;
    wire [23:0] src_pix_data;
    wire src_pix_sof;
    wire src_pix_eof;

    assign src_pix_valid = tp_de;
    assign src_pix_data  = {tp_r, tp_g, tp_b};

    assign src_pix_sof = tp_de &&
                         (tp_h_cnt == ACT_H_START) &&
                         (tp_v_cnt == ACT_V_START);

    assign src_pix_eof = tp_de &&
                         (tp_h_cnt == (ACT_H_END - 1)) &&
                         (tp_v_cnt == (ACT_V_END - 1));

    //==========================================================================
    // 5) TX packer -> TX word FIFO
    //==========================================================================
    wire        tx_pack_valid;
    wire [31:0] tx_pack_data;
    wire        tx_pack_sof;
    wire        tx_pack_eof;
    wire        tx_pack_align_err;

    wire [35:0] tx_word_fifo_din;
    wire [35:0] tx_word_fifo_dout;
    wire        tx_word_fifo_wr_en;
    wire        tx_word_fifo_rd_en;
    wire        tx_word_fifo_empty;
    wire        tx_word_fifo_full;
    wire        tx_word_fifo_almost_empty;
    wire        tx_word_fifo_almost_full;

    reg         tx_word_fifo_overflow_sticky;

    assign tx_word_fifo_din   = {2'b00, tx_pack_eof, tx_pack_sof, tx_pack_data};
    assign tx_word_fifo_wr_en = tx_pack_valid & (~tx_word_fifo_full);

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            tx_word_fifo_overflow_sticky <= 1'b0;
        end
        else if (tx_pack_valid && tx_word_fifo_full) begin
            tx_word_fifo_overflow_sticky <= 1'b1;
        end
    end

    //==========================================================================
    // 6) TX protocol packetizer
    //==========================================================================
    wire [31:0] proto_tx_user_data;
    wire        proto_tx_user_valid;
    wire        proto_tx_user_last;
    wire [3:0]  proto_tx_user_strb;

    wire [15:0] dbg_tx_frame_id;
    wire [15:0] dbg_tx_frag_id;
    wire [15:0] dbg_tx_frag_total;
    wire [7:0]  dbg_tx_seq;
    wire [7:0]  dbg_tx_pkt_type;
    wire [3:0]  dbg_tx_state;
    wire        dbg_tx_err_sticky;

    //==========================================================================
    // 7) RX protocol depacketizer -> RX word FIFO
    //==========================================================================
    wire [35:0] rx_word_fifo_din;
    wire        rx_word_fifo_wr_en;
    wire        rx_word_fifo_full;

    wire [15:0] dbg_rx_frame_id;
    wire [15:0] dbg_rx_frag_id;
    wire [15:0] dbg_rx_frag_total;
    wire [7:0]  dbg_rx_seq;
    wire [7:0]  dbg_rx_pkt_type;
    wire        dbg_rx_hdr_crc_ok;
    wire        dbg_rx_crc32_ok;
    wire [3:0]  dbg_rx_state;
    wire        dbg_rx_err_sticky;

    wire [35:0] rx_word_fifo_dout;
    wire        rx_word_fifo_rd_en;
    wire        rx_word_fifo_empty;
    wire        rx_word_fifo_almost_empty;
    wire        rx_word_fifo_almost_full;

    reg         rx_word_fifo_overflow_sticky;
    reg         rx_word_fifo_overflow_meta_pclk;
    reg         rx_word_fifo_overflow_pclk;

    always @(posedge sys_clk or posedge sys_rst) begin
        if (sys_rst) begin
            rx_word_fifo_overflow_sticky <= 1'b0;
        end
        else if (rx_word_fifo_wr_en && rx_word_fifo_full) begin
            rx_word_fifo_overflow_sticky <= 1'b1;
        end
    end

    //==========================================================================
    // 8) RX unpacker（pixel_clk 域）
    //==========================================================================
    wire        rx_pix_valid;
    wire [23:0] rx_pix_data;
    wire        rx_pix_sof;
    wire        rx_pix_eof;
    wire        rx_unpack_err_sticky;

    wire        rx_pix_ready;

    //==========================================================================
    // 9) stream ready / 显示状态
    //==========================================================================
    reg channel_up_meta_pclk;
    reg channel_up_pclk;

    reg rx_proto_err_meta_pclk;
    reg rx_proto_err_pclk;

    reg rx_stream_enable_pclk;
    reg rx_underflow_sticky_pclk;

    wire [23:0] local_rgb888;
    wire [23:0] loop_rgb888;
    wire [23:0] hdmi_rgb888;

    wire        link_bad_pclk;
    wire        proto_bad_pclk;
    wire        fifo_bad_pclk;
    wire [23:0] status_rgb888;

    assign local_rgb888 = {tp_r, tp_g, tp_b};

    generate
        if (DEBUG_VISUALIZE_RX) begin : G_VIS
            assign loop_rgb888 = {rx_pix_data[7:0], ~rx_pix_data[15:8], rx_pix_data[23:16]};
        end
        else begin : G_RAW
            assign loop_rgb888 = rx_pix_data;
        end
    endgenerate

    assign link_bad_pclk  = ~channel_up_pclk;
    assign proto_bad_pclk = rx_proto_err_pclk;
    assign fifo_bad_pclk  = rx_word_fifo_overflow_pclk | rx_underflow_sticky_pclk;

    // 显示状态色：
    // 1) link bad   -> 红闪
    // 2) proto bad  -> 黄
    // 3) fifo bad   -> 品红
    // 4) not ready  -> 蓝
    assign status_rgb888 =
        link_bad_pclk             ? {frame_cnt[4] ? 8'hFF : 8'h20, 8'h00, 8'h00} :
        proto_bad_pclk            ? 24'hFFFF00 :
        fifo_bad_pclk             ? 24'hFF00FF :
                                    24'h0000FF;

    // unpacker 在 active 区持续按需吐像素
    assign rx_pix_ready = tp_de && channel_up_pclk && (~rx_proto_err_pclk);

    // HDMI 输出逻辑：
    // active 区内：
    //   - stream_ready 且 rx_pix_valid -> 回环图
    //   - 否则 -> 状态色
    // blanking 区：
    //   - 输出 0（无所谓，因为 de=0）
    assign hdmi_rgb888 =
        tp_de ?
            ((rx_stream_enable_pclk && rx_pix_valid) ? loop_rgb888 : status_rgb888)
            : 24'h000000;

    // 当看到一帧回环像素的首像素后，允许切换到回环显示
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            channel_up_meta_pclk      <= 1'b0;
            channel_up_pclk           <= 1'b0;
            rx_proto_err_meta_pclk    <= 1'b0;
            rx_proto_err_pclk         <= 1'b0;
            rx_word_fifo_overflow_meta_pclk <= 1'b0;
            rx_word_fifo_overflow_pclk      <= 1'b0;

            rx_stream_enable_pclk     <= 1'b0;
            rx_underflow_sticky_pclk  <= 1'b0;
        end
        else begin
            channel_up_meta_pclk      <= channel_up;
            channel_up_pclk           <= channel_up_meta_pclk;

            rx_proto_err_meta_pclk    <= dbg_rx_err_sticky;
            rx_proto_err_pclk         <= rx_proto_err_meta_pclk;

            rx_word_fifo_overflow_meta_pclk <= rx_word_fifo_overflow_sticky;
            rx_word_fifo_overflow_pclk      <= rx_word_fifo_overflow_meta_pclk;

            if (!channel_up_pclk || rx_proto_err_pclk) begin
                rx_stream_enable_pclk    <= 1'b0;
                rx_underflow_sticky_pclk <= 1'b0;
            end
            else begin
                if (rx_pix_valid && rx_pix_sof)
                    rx_stream_enable_pclk <= 1'b1;

                if (tp_de && rx_stream_enable_pclk && !rx_pix_valid)
                    rx_underflow_sticky_pclk <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 10) 固定连接 / LED / TEST
    //==========================================================================
    assign sfp1_tx_disable_o = 1'b0;
    assign sfp2_tx_disable_o = 1'b0;
    assign tx_o              = 1'b1;   // 串口预留

    assign led_o[0] = cfg_pll_lock;
    assign led_o[1] = gt_pll_ok;
    assign led_o[2] = channel_up;
    assign led_o[3] = mon_good_pkt_seen_sticky;
    
    assign test_o[0] = tx_word_fifo_overflow_sticky;
    assign test_o[1] = rx_word_fifo_overflow_sticky;
    assign test_o[2] = mon_drop_seen_sticky;
    assign test_o[3] = mon_err_seen_sticky;
    //==========================================================================
    // 11) RoraLink 时钟 / 复位骨架（沿用稳定版）
    //==========================================================================
    assign sys_clk         = gt_pcs_tx_clk[0];
    assign gt_reset        = 1'b0;
    assign gt_pcs_tx_reset = 1'b0;
    assign gt_pcs_rx_reset = 1'b0;

    assign sys_reset_gen   = cfg_pll_lock & gt_pll_ok & resetn_i;

    Gowin_PLL u_Gowin_PLL
    (
        .reset      ( !resetn_i     ),
        .lock       ( cfg_pll_lock  ),
        .clkout0    ( cfg_clk       ),
        .clkin      ( osc_clk_i     )
    );

    reset_gen u_cfg_reset_gen
    (
        .i_clk1     ( cfg_clk       ),
        .i_lock     ( cfg_pll_lock  ),
        .o_rst1     ( cfg_rst       )
    );

    reset_gen u_sys_reset_gen
    (
        .i_clk1     ( sys_clk       ),
        .i_lock     ( sys_reset_gen ),
        .o_rst1     ( sys_rst       )
    );

    //==========================================================================
    // 12) SerDes_Top（Framing）
    //==========================================================================
    SerDes_Top u_SerDes_Top
    (
        .RoraLink_8B10B_Top_reset_i               ( sys_rst            ),
        .RoraLink_8B10B_Top_user_clk_i            ( sys_clk            ),
        .RoraLink_8B10B_Top_init_clk_i            ( cfg_clk            ),
        .RoraLink_8B10B_Top_user_pll_locked_i     ( gt_pll_ok          ),

        .RoraLink_8B10B_Top_link_reset_o          ( link_reset         ),
        .RoraLink_8B10B_Top_sys_reset_o           ( sys_reset          ),

        .RoraLink_8B10B_Top_user_tx_data_i        ( user_tx_data       ),
        .RoraLink_8B10B_Top_user_tx_valid_i       ( user_tx_valid      ),
        .RoraLink_8B10B_Top_user_tx_ready_o       ( user_tx_ready      ),
        .RoraLink_8B10B_Top_user_tx_strb_i        ( user_tx_strb       ),
        .RoraLink_8B10B_Top_user_tx_last_i        ( user_tx_last       ),

        .RoraLink_8B10B_Top_user_rx_data_o        ( user_rx_data       ),
        .RoraLink_8B10B_Top_user_rx_valid_o       ( user_rx_valid      ),
        .RoraLink_8B10B_Top_user_rx_strb_o        ( user_rx_strb       ),
        .RoraLink_8B10B_Top_user_rx_last_o        ( user_rx_last       ),

        .RoraLink_8B10B_Top_crc_pass_fail_n_o     ( crc_pass_fail_n    ),
        .RoraLink_8B10B_Top_crc_valid_o           ( crc_valid          ),

        .RoraLink_8B10B_Top_hard_err_o            ( hard_err           ),
        .RoraLink_8B10B_Top_soft_err_o            ( soft_err           ),
        .RoraLink_8B10B_Top_frame_err_o           ( frame_err          ),

        .RoraLink_8B10B_Top_channel_up_o          ( channel_up         ),
        .RoraLink_8B10B_Top_lane_up_o             ( lane_up            ),

        .RoraLink_8B10B_Top_gt_pcs_tx_reset_i     ( gt_pcs_tx_reset    ),
        .RoraLink_8B10B_Top_gt_pcs_tx_clk_o       ( gt_pcs_tx_clk      ),

        .RoraLink_8B10B_Top_gt_pcs_rx_reset_i     ( gt_pcs_rx_reset    ),
        .RoraLink_8B10B_Top_gt_rx_align_link_o    ( gt_rx_align_link   ),
        .RoraLink_8B10B_Top_gt_rx_pma_lock_o      ( gt_rx_pma_lock     ),
        .RoraLink_8B10B_Top_gt_rx_k_lock_o        ( gt_rx_k_lock       ),
        .RoraLink_8B10B_Top_gt_pcs_rx_clk_o       ( gt_pcs_rx_clk      ),

        .RoraLink_8B10B_Top_gt_reset_i            ( gt_reset           ),
        .RoraLink_8B10B_Top_gt_pll_lock_o         ( gt_pll_ok          )
    );

    //==========================================================================
    // 13) pixel clock / ADV7513 / testpattern
    //==========================================================================
    Gowin_PLL_pixel u_pixel_pll
    (
        .clkin      ( osc_clk_i       ),
        .init_clk   ( osc_clk_i       ),
        .clkout0    ( pixel_clk       ),
        .lock       ( pixel_clk_lock  ),
        .reset      ( !resetn_i       )
    );

    reset_gen u_pixel_reset_gen
    (
        .i_clk1     ( pixel_clk       ),
        .i_lock     ( pixel_clk_lock  ),
        .o_rst1     ( pixel_rst       )
    );

    wire        TX_EN_7513;
    wire [2:0]  WADDR_7513;
    wire [7:0]  WDATA_7513;
    wire        RX_EN_7513;
    wire [2:0]  RADDR_7513;
    wire [7:0]  RDATA_7513;

    adv7513_iic_init adv7513_iic_init_inst0
    (
        .I_CLK      (osc_clk_i),
        .I_RESETN   (resetn_i),
        .start      (pixel_rst_n),
        .O_TX_EN    (TX_EN_7513),
        .O_WADDR    (WADDR_7513),
        .O_WDATA    (WDATA_7513),
        .O_RX_EN    (RX_EN_7513),
        .O_RADDR    (RADDR_7513),
        .I_RDATA    (RDATA_7513),
        .cstate_flag(),
        .error_flag ()
    );

    I2C_MASTER_Top I2C_MASTER_Top_inst0
    (
        .I_CLK      (osc_clk_i),
        .I_RESETN   (pixel_rst_n),
        .I_TX_EN    (TX_EN_7513),
        .I_WADDR    (WADDR_7513),
        .I_WDATA    (WDATA_7513),
        .I_RX_EN    (RX_EN_7513),
        .I_RADDR    (RADDR_7513),
        .O_RDATA    (RDATA_7513),
        .O_IIC_INT  (),
        .SCL        (IO_adv7513_scl),
        .SDA        (IO_adv7513_sda)
    );

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            tp_vs_d <= 1'b0;
        else
            tp_vs_d <= tp_vs;
    end

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            frame_cnt <= 10'd0;
        else if (tp_vs_d && !tp_vs)
            frame_cnt <= frame_cnt + 1'b1;
    end

    testpattern testpattern_inst0
    (
        .I_pxl_clk   (pixel_clk),
        .I_rst_n     (pixel_rst_n),
        .I_mode      ({1'b0, 1'b0, frame_cnt[7]}),
        .I_sqr_width (16'd60),
        .I_single_r  (8'd0),
        .I_single_g  (8'd255),
        .I_single_b  (8'd0),
        .I_h_total   (C_H_TOTAL),
        .I_h_sync    (C_H_SYNC),
        .I_h_bporch  (C_H_BPORCH),
        .I_h_res     (C_H_RES),
        .I_v_total   (C_V_TOTAL),
        .I_v_sync    (C_V_SYNC),
        .I_v_bporch  (C_V_BPORCH),
        .I_v_res     (C_V_RES),
        .I_hs_pol    (1'b1),
        .I_vs_pol    (1'b1),
        .O_V_cnt     (tp_v_cnt),
        .O_H_cnt     (tp_h_cnt),
        .O_de        (tp_de),
        .O_hs        (tp_hs),
        .O_vs        (tp_vs),
        .O_data_r    (tp_r),
        .O_data_g    (tp_g),
        .O_data_b    (tp_b)
    );

    assign O_adv7513_data = hdmi_rgb888;
    assign O_adv7513_vs   = tp_vs;
    assign O_adv7513_hs   = tp_hs;
    assign O_adv7513_de   = tp_de;
    assign O_adv7513_clk  = pixel_clk;

    //==========================================================================
    // 14) Packer / Unpacker
    //==========================================================================
    tx_rgb888_packer_v1_0 u_tx_rgb888_packer_v1_0
    (
        .i_clk              (pixel_clk),
        .i_rst_n            (pixel_rst_n),

        .i_pix_valid        (src_pix_valid),
        .i_pix_data         (src_pix_data),
        .i_pix_sof          (src_pix_sof),
        .i_pix_eof          (src_pix_eof),

        .o_word_valid       (tx_pack_valid),
        .o_word_data        (tx_pack_data),
        .o_word_sof         (tx_pack_sof),
        .o_word_eof         (tx_pack_eof),

        .o_align_err_sticky (tx_pack_align_err)
    );

    rx_rgb888_unpacker_v1_0 u_rx_rgb888_unpacker_v1_0
    (
        .i_clk               (pixel_clk),
        .i_rst_n             (pixel_rst_n),

        .i_fifo_dout         (rx_word_fifo_dout),
        .i_fifo_empty        (rx_word_fifo_empty),
        .o_fifo_rd_en        (rx_word_fifo_rd_en),

        .i_pix_ready         (rx_pix_ready),

        .o_pix_valid         (rx_pix_valid),
        .o_pix_data          (rx_pix_data),
        .o_pix_sof           (rx_pix_sof),
        .o_pix_eof           (rx_pix_eof),

        .o_format_err_sticky (rx_unpack_err_sticky)
    );

    //==========================================================================
    // 15) 协议 TX / RX
    //==========================================================================
    proto_video_tx_packetizer_v1_1
    #(
        .ACTIVE_W        (1920),
        .ACTIVE_H        (1080),
        .PAYLOAD_BYTES   (1024),
        .CHANNEL_ID      (8'd0),
        .PIX_FMT         (8'h01),
        .TYPE_VIDEO_FS   (8'h01),
        .TYPE_VIDEO_PAY  (8'h11),
        .TYPE_VIDEO_FE   (8'h21)
    )
    u_proto_video_tx_packetizer_v1_1
    (
        .i_clk              (sys_clk),
        .i_rst_n            (~sys_rst),

        .i_word_fifo_empty  (tx_word_fifo_empty),
        .i_word_fifo_dout   (tx_word_fifo_dout),
        .i_word_fifo_rnum   (tx_word_fifo_rnum),
        .o_word_fifo_rd_en  (tx_word_fifo_rd_en),

        .i_user_tx_ready    (user_tx_ready),

        .o_user_tx_data     (proto_tx_user_data),
        .o_user_tx_valid    (proto_tx_user_valid),
        .o_user_tx_last     (proto_tx_user_last),
        .o_user_tx_strb     (proto_tx_user_strb),

        .o_dbg_frame_id     (dbg_tx_frame_id),
        .o_dbg_frag_id      (dbg_tx_frag_id),
        .o_dbg_frag_total   (dbg_tx_frag_total),
        .o_dbg_seq          (dbg_tx_seq),
        .o_dbg_pkt_type     (dbg_tx_pkt_type),
        .o_dbg_state        (dbg_tx_state),
        .o_dbg_err_sticky   (dbg_tx_err_sticky)
    );
    
    proto_video_rx_depacketizer_v1_0
    #(
        .CHANNEL_ID      (8'd0),
        .PIX_FMT         (8'h01),
        .TYPE_VIDEO_FS   (8'h01),
        .TYPE_VIDEO_PAY  (8'h11),
        .TYPE_VIDEO_FE   (8'h21)
    )
    u_proto_video_rx_depacketizer_v1_0
    (
        .i_clk              (sys_clk),
        .i_rst_n            (~sys_rst),

        .i_user_rx_data     (user_rx_data),
        .i_user_rx_valid    (user_rx_valid),
        .i_user_rx_last     (user_rx_last),

        .o_word_fifo_din    (rx_word_fifo_din),
        .o_word_fifo_wr_en  (rx_word_fifo_wr_en),
        .i_word_fifo_full   (rx_word_fifo_full),

        .o_dbg_frame_id     (dbg_rx_frame_id),
        .o_dbg_frag_id      (dbg_rx_frag_id),
        .o_dbg_frag_total   (dbg_rx_frag_total),
        .o_dbg_seq          (dbg_rx_seq),
        .o_dbg_pkt_type     (dbg_rx_pkt_type),
        .o_dbg_hdr_crc_ok   (dbg_rx_hdr_crc_ok),
        .o_dbg_crc32_ok     (dbg_rx_crc32_ok),
        .o_dbg_state        (dbg_rx_state),
        .o_dbg_err_sticky   (dbg_rx_err_sticky)
    );

    // RoraLink TX 接协议 TX
    assign user_tx_data  = proto_tx_user_data;
    assign user_tx_valid = proto_tx_user_valid;
    assign user_tx_last  = proto_tx_user_last;
    assign user_tx_strb  = proto_tx_user_strb;

    //==========================================================================
    // 16) TX / RX word async FIFO（请按此接口风格生成）
    //==========================================================================
    wire [12:0] tx_word_fifo_rnum;

    fifo_top_tx36x4096 u_fifo_top_tx36x4096
    (
        .Data           (tx_word_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (pixel_clk),
        .RdClk          (sys_clk),
        .WrEn           (tx_word_fifo_wr_en),
        .RdEn           (tx_word_fifo_rd_en),
        .Rnum           (tx_word_fifo_rnum),
        .Almost_Empty   (tx_word_fifo_almost_empty),
        .Almost_Full    (tx_word_fifo_almost_full),
        .Q              (tx_word_fifo_dout),
        .Empty          (tx_word_fifo_empty),
        .Full           (tx_word_fifo_full)
    );

    fifo_top_rx36x4096 u_fifo_top_rx36x4096
    (
        .Data           (rx_word_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (sys_clk),
        .RdClk          (pixel_clk),
        .WrEn           (rx_word_fifo_wr_en),
        .RdEn           (rx_word_fifo_rd_en),
        .Almost_Empty   (rx_word_fifo_almost_empty),
        .Almost_Full    (),
        .Q              (rx_word_fifo_dout),
        .Empty          (rx_word_fifo_empty),
        .Full           (rx_word_fifo_full)
    );

    //==========================================================================
    // 17) ILA 观测信号（建议先抓这些）
    //==========================================================================
    (* keep = "true" *) wire [31:0] ila_top_version          = TOP_VERSION;

    // packer
    (* keep = "true" *) wire        ila_src_pix_valid        = src_pix_valid;
    (* keep = "true" *) wire        ila_src_pix_sof          = src_pix_sof;
    (* keep = "true" *) wire        ila_src_pix_eof          = src_pix_eof;
    (* keep = "true" *) wire        ila_tx_pack_valid        = tx_pack_valid;
    (* keep = "true" *) wire [31:0] ila_tx_pack_data         = tx_pack_data;
    (* keep = "true" *) wire        ila_tx_pack_sof          = tx_pack_sof;
    (* keep = "true" *) wire        ila_tx_pack_eof          = tx_pack_eof;
    (* keep = "true" *) wire        ila_tx_pack_align_err    = tx_pack_align_err;

    // tx fifo / tx proto
    (* keep = "true" *) wire        ila_tx_word_fifo_empty   = tx_word_fifo_empty;
    (* keep = "true" *) wire        ila_tx_word_fifo_full    = tx_word_fifo_full;
    (* keep = "true" *) wire        ila_tx_word_fifo_wr_en   = tx_word_fifo_wr_en;
    (* keep = "true" *) wire        ila_tx_word_fifo_rd_en   = tx_word_fifo_rd_en;
    (* keep = "true" *) wire [15:0] ila_dbg_tx_frame_id      = dbg_tx_frame_id;
    (* keep = "true" *) wire [15:0] ila_dbg_tx_frag_id       = dbg_tx_frag_id;
    (* keep = "true" *) wire [15:0] ila_dbg_tx_frag_total    = dbg_tx_frag_total;
    (* keep = "true" *) wire [7:0]  ila_dbg_tx_seq           = dbg_tx_seq;
    (* keep = "true" *) wire [7:0]  ila_dbg_tx_pkt_type      = dbg_tx_pkt_type;
    (* keep = "true" *) wire [3:0]  ila_dbg_tx_state         = dbg_tx_state;
    (* keep = "true" *) wire        ila_dbg_tx_err_sticky    = dbg_tx_err_sticky;

    // rx proto / rx fifo
    (* keep = "true" *) wire [15:0] ila_dbg_rx_frame_id      = dbg_rx_frame_id;
    (* keep = "true" *) wire [15:0] ila_dbg_rx_frag_id       = dbg_rx_frag_id;
    (* keep = "true" *) wire [15:0] ila_dbg_rx_frag_total    = dbg_rx_frag_total;
    (* keep = "true" *) wire [7:0]  ila_dbg_rx_seq           = dbg_rx_seq;
    (* keep = "true" *) wire [7:0]  ila_dbg_rx_pkt_type      = dbg_rx_pkt_type;
    (* keep = "true" *) wire        ila_dbg_rx_hdr_crc_ok    = dbg_rx_hdr_crc_ok;
    (* keep = "true" *) wire        ila_dbg_rx_crc32_ok      = dbg_rx_crc32_ok;
    (* keep = "true" *) wire [3:0]  ila_dbg_rx_state         = dbg_rx_state;
    (* keep = "true" *) wire        ila_dbg_rx_err_sticky    = dbg_rx_err_sticky;
    (* keep = "true" *) wire        ila_rx_word_fifo_empty   = rx_word_fifo_empty;
    (* keep = "true" *) wire        ila_rx_word_fifo_full    = rx_word_fifo_full;
    (* keep = "true" *) wire        ila_rx_word_fifo_wr_en   = rx_word_fifo_wr_en;
    (* keep = "true" *) wire        ila_rx_word_fifo_rd_en   = rx_word_fifo_rd_en;

    // unpack / display
    (* keep = "true" *) wire        ila_rx_pix_ready         = rx_pix_ready;
    (* keep = "true" *) wire        ila_rx_pix_valid         = rx_pix_valid;
    (* keep = "true" *) wire [23:0] ila_rx_pix_data          = rx_pix_data;
    (* keep = "true" *) wire        ila_rx_pix_sof           = rx_pix_sof;
    (* keep = "true" *) wire        ila_rx_pix_eof           = rx_pix_eof;
    (* keep = "true" *) wire        ila_rx_unpack_err        = rx_unpack_err_sticky;
    (* keep = "true" *) wire        ila_rx_stream_enable     = rx_stream_enable_pclk;
    (* keep = "true" *) wire        ila_rx_underflow         = rx_underflow_sticky_pclk;


    (* keep = "true" *) wire [12:0] ila_tx_word_fifo_rnum = tx_word_fifo_rnum;

    wire        mon_hdr_seen_sticky;
    wire        mon_good_pkt_seen_sticky;
    wire        mon_err_seen_sticky;
    wire        mon_drop_seen_sticky;

    wire [31:0] mon_hdr_ok_cnt;
    wire [31:0] mon_crc_ok_cnt;
    wire [31:0] mon_good_fs_cnt;
    wire [31:0] mon_good_pay_cnt;
    wire [31:0] mon_good_fe_cnt;

    wire [7:0]  mon_last_good_type;
    wire [7:0]  mon_last_good_seq;

    rx_packet_monitor_v1_0 u_rx_packet_monitor_v1_0
    (
        .i_clk                  (sys_clk),
        .i_rst_n                (~sys_rst),

        .i_dbg_rx_pkt_type      (dbg_rx_pkt_type),
        .i_dbg_rx_seq           (dbg_rx_seq),
        .i_dbg_rx_hdr_crc_ok    (dbg_rx_hdr_crc_ok),
        .i_dbg_rx_crc32_ok      (dbg_rx_crc32_ok),
        .i_dbg_rx_err_sticky    (dbg_rx_err_sticky),
        .i_dbg_rx_state         (dbg_rx_state),

        .o_hdr_seen_sticky      (mon_hdr_seen_sticky),
        .o_good_pkt_seen_sticky (mon_good_pkt_seen_sticky),
        .o_err_seen_sticky      (mon_err_seen_sticky),
        .o_drop_seen_sticky     (mon_drop_seen_sticky),

        .o_hdr_ok_cnt           (mon_hdr_ok_cnt),
        .o_crc_ok_cnt           (mon_crc_ok_cnt),
        .o_good_fs_cnt          (mon_good_fs_cnt),
        .o_good_pay_cnt         (mon_good_pay_cnt),
        .o_good_fe_cnt          (mon_good_fe_cnt),

        .o_last_good_type       (mon_last_good_type),
        .o_last_good_seq        (mon_last_good_seq)
    );

endmodule


//==============================================================================
// reset_gen
//==============================================================================
module reset_gen
(
    input           i_clk1,
    input           i_lock,
    output reg      o_rst1 = 1'b1
);

reg [11:0] r_cnt = 12'd0;

always @(posedge i_clk1) begin
    if (!i_lock) begin
        r_cnt  <= 12'd0;
        o_rst1 <= 1'b1;
    end
    else if (r_cnt < 12'hfff) begin
        r_cnt  <= r_cnt + 12'd1;
        o_rst1 <= 1'b1;
    end
    else begin
        o_rst1 <= 1'b0;
    end
end

endmodule