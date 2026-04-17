`timescale 1ns / 1ps

/*********************************************************************************
* Module       : top
* Style tag    : top_full_timing_stream_demo_v2
* Description  :
*   720p60 full-timing video stream + UART text-command demo control plane
*   + source pattern mode switch
*   + menu OSD overlay
*   + link-down red flash
*
* Text commands (terminated by '\n', "\r\n" also supported):
*   OSD ON
*   OSD OFF
*   OSD TOGGLE
*   MENU UP
*   MENU DOWN
*   MODE SET COLORBAR
*   MODE SET NETGRID
*   MODE SET GRAY
*   MODE SET BWSQUARE
*   MODE SET RED
*   MODE SET GREEN
*   STATUS?
*   RESET
*   HELP?
*
* Notes:
*   1) HDMI timing 始终来自本地稳定 testpattern timing
*   2) 返回视频流只作为 RGB 内容来源
*   3) pattern mode 在帧边界生效，避免半帧切换
*   4) RX 命令字节在 parser 前做单拍整形，避免重复采样
*********************************************************************************/

module top
(
    input           osc_clk_i,
    input           resetn_i,

    output          sfp1_tx_disable_o,
    output          sfp2_tx_disable_o,

    input           rx_i,               // UART RX
    output          tx_o,               // UART TX

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
    localparam LANE_WIDTH      = `LANE_WIDTH;
    localparam LANE_DATA_WIDTH = `LANE_DATA_WIDTH;

    // 720p60 timing
    localparam [15:0] C_H_TOTAL  = 16'd1650;
    localparam [15:0] C_H_SYNC   = 16'd40;
    localparam [15:0] C_H_BPORCH = 16'd220;
    localparam [15:0] C_H_RES    = 16'd1280;

    localparam [15:0] C_V_TOTAL  = 16'd750;
    localparam [15:0] C_V_SYNC   = 16'd5;
    localparam [15:0] C_V_BPORCH = 16'd20;
    localparam [15:0] C_V_RES    = 16'd720;

    localparam [15:0] RX_PREFILL_CYCLES = 16'd1024;

    // UART 参数（sys_clk≈78.125MHz, baud=115200）
    localparam integer UART_CLKS_PER_BIT = 678;

    localparam integer CTRL_FIFO_DEPTH  = 64;
    localparam integer CTRL_FIFO_AW     = 6;

    localparam integer CMD_MAX_CHARS    = 31;
    localparam integer RESP_MAX_CHARS   = 96;

    //==========================================================================
    // 1) RoraLink streaming 用户接口
    //==========================================================================
    wire [DATA_WIDTH-1:0] user_tx_data;
    wire                  user_tx_valid;
    wire                  user_tx_ready;

    wire [DATA_WIDTH-1:0] user_rx_data;
    wire                  user_rx_valid;

    wire                  hard_err;
    wire                  soft_err;
    wire                  channel_up;
    wire [LANE_WIDTH-1:0] lane_up;

    //==========================================================================
    // 2) 时钟 / 复位 / GT 状态
    //==========================================================================
    wire                  sys_clk /* synthesis syn_keep=1 */;
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
    // 3) pixel / 本地 720p 源
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

    // pattern / source mode control (pixel_clk 域)
    reg  [2:0]  pattern_mode_meta    = 3'd0;
    reg  [2:0]  pattern_mode_pending = 3'd0;
    reg  [2:0]  pattern_mode_active  = 3'd0;

    reg  [2:0]  tp_mode_active       = 3'b000;
    reg  [7:0]  tp_single_r_active   = 8'd0;
    reg  [7:0]  tp_single_g_active   = 8'd255;
    reg  [7:0]  tp_single_b_active   = 8'd0;

    wire        tp_frame_start;
    assign tp_frame_start = (tp_h_cnt == 16'd0) && (tp_v_cnt == 16'd0);

    reg         tp_vs_d   = 1'b0;
    reg  [7:0]  blink_cnt = 8'd0;

    //==========================================================================
    // 4) TX: full timing symbol packer -> TX_VIDEO FIFO
    //==========================================================================
    wire [31:0] tx_video_word_data;
    wire        tx_video_word_valid;
    wire        tx_video_overflow_sticky;

    wire [35:0] tx_video_fifo_din;
    wire [35:0] tx_video_fifo_dout;
    wire        tx_video_fifo_wr_en;
    wire        tx_video_fifo_rd_en;
    wire        tx_video_fifo_empty;
    wire        tx_video_fifo_full;
    wire [12:0] tx_video_fifo_rnum;

    assign tx_video_fifo_din   = {4'b0000, tx_video_word_data};
    assign tx_video_fifo_wr_en = tx_video_word_valid & (~tx_video_fifo_full);

    //==========================================================================
    // 5) TX: UART RX -> uart_word_packer -> TX_CTRL FIFO
    //==========================================================================
    wire [7:0]  uart_rx_byte;
    wire        uart_rx_byte_valid;

    wire [31:0] tx_ctrl_word_data;
    wire        tx_ctrl_word_valid;
    wire [7:0]  tx_ctrl_dbg_seq;
    wire        tx_ctrl_overflow_sticky_from_packer;

    wire [31:0] tx_ctrl_fifo_dout;
    wire        tx_ctrl_fifo_empty;
    wire        tx_ctrl_fifo_full;
    wire        tx_ctrl_fifo_wr_en;
    wire        tx_ctrl_fifo_rd_en;
    wire [31:0] tx_ctrl_fifo_din;

    assign tx_ctrl_fifo_din   = tx_ctrl_word_data;
    assign tx_ctrl_fifo_wr_en = tx_ctrl_word_valid & (~tx_ctrl_fifo_full);

    //==========================================================================
    // 6) TX 复用：video + ctrl -> 单路 streaming TX
    //==========================================================================
    wire [31:0] mux_tx_data;
    wire        mux_tx_valid;

    wire        mux_dbg_sel_video;
    wire        mux_dbg_sel_ctrl;
    wire [7:0]  mux_dbg_video_burst_left;
    wire        mux_dbg_video_force_mode;

    //==========================================================================
    // 7) RX 解复用：单路 streaming RX -> RX_VIDEO FIFO + RX_CTRL FIFO
    //==========================================================================
    wire [31:0] rx_video_fifo_din_32;
    wire        rx_video_fifo_wr_en;

    wire [31:0] rx_ctrl_fifo_din;
    wire        rx_ctrl_fifo_wr_en;
    wire        rx_ctrl_fifo_empty;
    wire        rx_ctrl_fifo_full;
    wire [31:0] rx_ctrl_fifo_dout;
    wire        rx_ctrl_fifo_rd_en;

    wire        rx_video_overflow_sticky;
    wire        rx_ctrl_overflow_sticky;

    wire        demux_dbg_is_video;
    wire        demux_dbg_is_ctrl;

    wire [35:0] rx_video_fifo_din;
    wire [35:0] rx_video_fifo_dout;
    wire        rx_video_fifo_empty;
    wire        rx_video_fifo_full;
    wire        rx_video_fifo_rd_en;

    assign rx_video_fifo_din = {4'b0000, rx_video_fifo_din_32};

    //==========================================================================
    // 8) RX: video_symbol_unpacker（pixel_clk 域）
    //==========================================================================
    wire        rx_sym_valid;
    wire        rx_sym_vs;
    wire        rx_sym_hs;
    wire        rx_sym_de;
    wire [23:0] rx_sym_rgb;
    wire        rx_stream_underflow_sticky;

    //==========================================================================
    // 9) RX: UART control stream -> uart_word_unpacker -> line parser -> ctrl fsm
    //==========================================================================
    wire [7:0]  uart_rx_cmd_byte_from_link;
    wire        uart_rx_cmd_byte_valid_from_link;

    // 单拍整形后送 parser
    reg         uart_rx_cmd_byte_valid_d  = 1'b0;
    reg  [7:0]  uart_rx_cmd_byte_data_p1  = 8'd0;
    reg         uart_rx_cmd_byte_fire_p1  = 1'b0;

    // uart_word_unpacker debug
    wire [7:0]  uart_rx_link_last_seq;
    wire [7:0]  uart_rx_link_expected_seq;
    wire        uart_rx_type_err_sticky;
    wire        uart_rx_channel_err_sticky;
    wire        uart_rx_crc_err_sticky;
    wire        uart_rx_seq_err_sticky;

    // line parser
    wire [CMD_MAX_CHARS*8-1:0] cmd_line_data;
    wire [7:0]                 cmd_line_len;
    wire                       cmd_line_valid;
    wire                       cmd_line_overflow_sticky;
    wire                       cmd_empty_line_seen_pulse;

    // demo control FSM state
    wire                       ctrl_osd_on_sys;
    wire [2:0]                 ctrl_menu_index_sys;
    wire [2:0]                 ctrl_active_mode_sys;

    // demo control FSM structured response
    wire                       resp_valid;
    wire                       resp_ready;
    wire [3:0]                 resp_kind;
    wire [3:0]                 resp_err_code;
    wire                       resp_link_up;
    wire                       resp_osd_on;
    wire [2:0]                 resp_menu_index;
    wire [2:0]                 resp_active_mode;

    // FSM debug
    wire                       fsm_unknown_cmd_sticky;
    wire                       fsm_bad_arg_sticky;
    wire                       fsm_linkdown_cmd_sticky;
    wire                       fsm_cmd_while_busy_sticky;

    // formatter -> uart tx
    wire [7:0]                 resp_uart_byte;
    wire                       resp_uart_byte_valid;
    wire                       resp_fmt_busy;
    wire [7:0]                 resp_fmt_dbg_len;
    wire                       resp_fmt_overflow_sticky;
    wire                       uart_tx_ready;
    wire                       uart_tx_busy;

    //==========================================================================
    // 10) OSD / pattern / menu sync to pixel_clk
    //==========================================================================
    reg         osd_enable_meta   = 1'b0;
    reg         osd_enable_pclk   = 1'b0;

    reg  [2:0]  menu_index_meta   = 3'd0;
    reg  [2:0]  menu_index_pclk   = 3'd0;

    //==========================================================================
    // 11) pixel 域流控 / 锁流
    //==========================================================================
    reg channel_up_meta_pclk  = 1'b0;
    reg channel_up_pclk       = 1'b0;
    reg channel_up_pclk_d     = 1'b0;

    reg [15:0] rx_prefill_cnt = 16'd0;
    reg        rx_read_enable_pclk   = 1'b0;
    reg        rx_stream_enable_pclk = 1'b0;

    reg        rx_sym_vs_d = 1'b0;

    wire channel_down_pulse_pclk;
    wire rx_vs_rise_pclk;

    assign channel_down_pulse_pclk = channel_up_pclk_d & (~channel_up_pclk);
    assign rx_vs_rise_pclk         = (~rx_sym_vs_d) & rx_sym_vs & rx_sym_valid;

    wire rx_video_ready_pclk;
    assign rx_video_ready_pclk = rx_read_enable_pclk;

    //==========================================================================
    // 12) HDMI 输出 / OSD / link down red flash
    //==========================================================================
    wire        hdmi_vs;
    wire        hdmi_hs;
    wire        hdmi_de;

    wire [23:0] link_up_rgb;
    wire [23:0] red_flash_rgb;
    wire [23:0] base_rgb;
    wire [23:0] osd_rgb;
    wire        osd_in_box;

    assign hdmi_vs = tp_vs;
    assign hdmi_hs = tp_hs;
    assign hdmi_de = tp_de;

    assign link_up_rgb =
        (tp_de && rx_stream_enable_pclk && rx_sym_valid && rx_sym_de) ? rx_sym_rgb
                                                                      : 24'h000000;

    assign red_flash_rgb = blink_cnt[5] ? 24'hFF0000 : 24'h200000;

    assign base_rgb = channel_up_pclk ? link_up_rgb : (tp_de ? red_flash_rgb : 24'h000000);

    //==========================================================================
    // 13) 内部调试信号 / LED
    //==========================================================================
    wire [3:0] test_sig /* synthesis syn_keep=1 */;

    assign test_sig[0] = tx_video_overflow_sticky | rx_stream_underflow_sticky;
    assign test_sig[1] = tx_ctrl_overflow_sticky_from_packer |
                         uart_rx_crc_err_sticky |
                         uart_rx_seq_err_sticky |
                         uart_rx_type_err_sticky |
                         uart_rx_channel_err_sticky;
    assign test_sig[2] = cmd_line_overflow_sticky |
                         resp_fmt_overflow_sticky;
    assign test_sig[3] = fsm_unknown_cmd_sticky |
                         fsm_bad_arg_sticky |
                         fsm_linkdown_cmd_sticky |
                         fsm_cmd_while_busy_sticky;

    assign sfp1_tx_disable_o = 1'b0;
    assign sfp2_tx_disable_o = 1'b0;

    assign led_o[0] = cfg_pll_lock;
    assign led_o[1] = gt_pll_ok;
    assign led_o[2] = channel_up;
    assign led_o[3] = osd_enable_pclk;

    //==========================================================================
    // 14) 时钟 / 复位
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

    //==========================================================================
    // 15) ADV7513 / 本地 720p 测试图
    //==========================================================================
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

    testpattern testpattern_inst0
    (
        .I_pxl_clk   (pixel_clk),
        .I_rst_n     (pixel_rst_n),
        .I_mode      (tp_mode_active),
        .I_sqr_width (16'd60),
        .I_single_r  (tp_single_r_active),
        .I_single_g  (tp_single_g_active),
        .I_single_b  (tp_single_b_active),
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

    //==========================================================================
    // 16) SerDes_Top（streaming mode）
    //==========================================================================
    SerDes_Top u_SerDes_Top
    (
        .RoraLink_8B10B_Top_link_reset_o          ( link_reset         ),
        .RoraLink_8B10B_Top_sys_reset_o           ( sys_reset          ),
        .RoraLink_8B10B_Top_user_tx_ready_o       ( user_tx_ready      ),
        .RoraLink_8B10B_Top_user_rx_data_o        ( user_rx_data       ),
        .RoraLink_8B10B_Top_user_rx_valid_o       ( user_rx_valid      ),
        .RoraLink_8B10B_Top_hard_err_o            ( hard_err           ),
        .RoraLink_8B10B_Top_soft_err_o            ( soft_err           ),
        .RoraLink_8B10B_Top_channel_up_o          ( channel_up         ),
        .RoraLink_8B10B_Top_lane_up_o             ( lane_up            ),
        .RoraLink_8B10B_Top_gt_pcs_tx_clk_o       ( gt_pcs_tx_clk      ),
        .RoraLink_8B10B_Top_gt_pcs_rx_clk_o       ( gt_pcs_rx_clk      ),
        .RoraLink_8B10B_Top_gt_pll_lock_o         ( gt_pll_ok          ),
        .RoraLink_8B10B_Top_gt_rx_align_link_o    ( gt_rx_align_link   ),
        .RoraLink_8B10B_Top_gt_rx_pma_lock_o      ( gt_rx_pma_lock     ),
        .RoraLink_8B10B_Top_gt_rx_k_lock_o        ( gt_rx_k_lock       ),

        .RoraLink_8B10B_Top_user_clk_i            ( sys_clk            ),
        .RoraLink_8B10B_Top_init_clk_i            ( cfg_clk            ),
        .RoraLink_8B10B_Top_reset_i               ( sys_rst            ),
        .RoraLink_8B10B_Top_user_pll_locked_i     ( gt_pll_ok          ),
        .RoraLink_8B10B_Top_user_tx_data_i        ( user_tx_data       ),
        .RoraLink_8B10B_Top_user_tx_valid_i       ( user_tx_valid      ),
        .RoraLink_8B10B_Top_gt_reset_i            ( gt_reset           ),
        .RoraLink_8B10B_Top_gt_pcs_tx_reset_i     ( gt_pcs_tx_reset    ),
        .RoraLink_8B10B_Top_gt_pcs_rx_reset_i     ( gt_pcs_rx_reset    )
    );

    //==========================================================================
    // 17) 视频发送端：打包完整 timing -> TX_VIDEO FIFO
    //==========================================================================
    video_symbol_packer_v1 u_video_symbol_packer_v1
    (
        .i_clk              (pixel_clk),
        .i_rst_n            (pixel_rst_n),

        .i_enable           (1'b1),
        .i_vs               (tp_vs),
        .i_hs               (tp_hs),
        .i_de               (tp_de),
        .i_rgb              ({tp_r, tp_g, tp_b}),

        .i_word_ready       (~tx_video_fifo_full),

        .o_word_data        (tx_video_word_data),
        .o_word_valid       (tx_video_word_valid),
        .o_overflow_sticky  (tx_video_overflow_sticky)
    );

    //==========================================================================
    // 18) UART 发送到链路：UART RX -> 控制字 -> TX_CTRL FIFO
    //==========================================================================
    uart_rx_byte_v1
    #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    )
    u_uart_rx_byte_v1
    (
        .i_clk          (sys_clk),
        .i_rst_n        (~sys_rst),
        .i_uart_rx      (rx_i),

        .o_byte_data    (uart_rx_byte),
        .o_byte_valid   (uart_rx_byte_valid)
    );

    uart_word_packer_v1
    #(
        .CHANNEL_ID(3'b000)
    )
    u_uart_word_packer_v1
    (
        .i_clk              (sys_clk),
        .i_rst_n            (~sys_rst),

        .i_byte_data        (uart_rx_byte),
        .i_byte_valid       (uart_rx_byte_valid),

        .i_word_ready       (~tx_ctrl_fifo_full),

        .o_word_data        (tx_ctrl_word_data),
        .o_word_valid       (tx_ctrl_word_valid),

        .o_dbg_seq          (tx_ctrl_dbg_seq),
        .o_overflow_sticky  (tx_ctrl_overflow_sticky_from_packer)
    );

    //==========================================================================
    // 19) TX 复用：ctrl 高优先级 + 视频高水位保护
    //==========================================================================
    stream_mux_qos_v1
    #(
        .VIDEO_HIGH_WATERMARK(13'd1024),
        .VIDEO_BURST_LEN     (8'd64)
    )
    u_stream_mux_qos_v1
    (
        .i_clk               (sys_clk),
        .i_rst_n             (~sys_rst),

        .i_video_fifo_dout   (tx_video_fifo_dout[31:0]),
        .i_video_fifo_empty  (tx_video_fifo_empty),
        .i_video_fifo_rnum   (tx_video_fifo_rnum),
        .o_video_fifo_rd_en  (tx_video_fifo_rd_en),

        .i_ctrl_fifo_dout    (tx_ctrl_fifo_dout),
        .i_ctrl_fifo_empty   (tx_ctrl_fifo_empty),
        .o_ctrl_fifo_rd_en   (tx_ctrl_fifo_rd_en),

        .o_mux_data          (mux_tx_data),
        .o_mux_valid         (mux_tx_valid),
        .i_mux_ready         (user_tx_ready),

        .o_dbg_sel_video     (mux_dbg_sel_video),
        .o_dbg_sel_ctrl      (mux_dbg_sel_ctrl),
        .o_dbg_video_burst_left(mux_dbg_video_burst_left),
        .o_dbg_video_force_mode(mux_dbg_video_force_mode)
    );

    assign user_tx_data  = mux_tx_data;
    assign user_tx_valid = mux_tx_valid;

    //==========================================================================
    // 20) RX 解复用：视频 -> RX_VIDEO FIFO，控制 -> RX_CTRL FIFO
    //==========================================================================
    stream_demux_v1 u_stream_demux_v1
    (
        .i_clk                  (sys_clk),
        .i_rst_n                (~sys_rst),

        .i_rx_data              (user_rx_data),
        .i_rx_valid             (user_rx_valid),

        .o_video_fifo_din       (rx_video_fifo_din_32),
        .o_video_fifo_wr_en     (rx_video_fifo_wr_en),
        .i_video_fifo_full      (rx_video_fifo_full),

        .o_ctrl_fifo_din        (rx_ctrl_fifo_din),
        .o_ctrl_fifo_wr_en      (rx_ctrl_fifo_wr_en),
        .i_ctrl_fifo_full       (rx_ctrl_fifo_full),

        .o_video_overflow_sticky(rx_video_overflow_sticky),
        .o_ctrl_overflow_sticky (rx_ctrl_overflow_sticky),

        .o_dbg_is_video         (demux_dbg_is_video),
        .o_dbg_is_ctrl          (demux_dbg_is_ctrl)
    );

    //==========================================================================
    // 21) RX 视频恢复：RX_VIDEO FIFO -> 本地 timing 下显示 RGB
    //==========================================================================
    video_symbol_unpacker_v1 u_video_symbol_unpacker_v1
    (
        .i_clk              (pixel_clk),
        .i_rst_n            (pixel_rst_n),

        .i_fifo_dout        (rx_video_fifo_dout[31:0]),
        .i_fifo_empty       (rx_video_fifo_empty),
        .o_fifo_rd_en       (rx_video_fifo_rd_en),

        .i_video_ready      (rx_video_ready_pclk),

        .o_valid            (rx_sym_valid),
        .o_vs               (rx_sym_vs),
        .o_hs               (rx_sym_hs),
        .o_de               (rx_sym_de),
        .o_rgb              (rx_sym_rgb),

        .o_underflow_sticky (rx_stream_underflow_sticky)
    );

    //==========================================================================
    // 22) RX 控制恢复：RX_CTRL FIFO -> UART byte stream from link
    //==========================================================================
    uart_word_unpacker_v1
    #(
        .CHANNEL_ID(3'b000)
    )
    u_uart_word_unpacker_v1
    (
        .i_clk               (sys_clk),
        .i_rst_n             (~sys_rst),

        .i_fifo_dout         (rx_ctrl_fifo_dout),
        .i_fifo_empty        (rx_ctrl_fifo_empty),
        .o_fifo_rd_en        (rx_ctrl_fifo_rd_en),

        .i_byte_ready        (1'b1),
        .o_byte_data         (uart_rx_cmd_byte_from_link),
        .o_byte_valid        (uart_rx_cmd_byte_valid_from_link),

        .o_dbg_last_seq      (uart_rx_link_last_seq),
        .o_dbg_expected_seq  (uart_rx_link_expected_seq),

        .o_type_err_sticky   (uart_rx_type_err_sticky),
        .o_channel_err_sticky(uart_rx_channel_err_sticky),
        .o_crc_err_sticky    (uart_rx_crc_err_sticky),
        .o_seq_err_sticky    (uart_rx_seq_err_sticky)
    );

    //==========================================================================
    // 23) RX 命令字节单拍整形
    //==========================================================================
    always @(posedge sys_clk or posedge sys_rst) begin
        if (sys_rst) begin
            uart_rx_cmd_byte_valid_d <= 1'b0;
            uart_rx_cmd_byte_data_p1 <= 8'd0;
            uart_rx_cmd_byte_fire_p1 <= 1'b0;
        end
        else begin
            uart_rx_cmd_byte_valid_d <= uart_rx_cmd_byte_valid_from_link;
            uart_rx_cmd_byte_fire_p1 <= 1'b0;

            if (uart_rx_cmd_byte_valid_from_link && !uart_rx_cmd_byte_valid_d) begin
                uart_rx_cmd_byte_data_p1 <= uart_rx_cmd_byte_from_link;
                uart_rx_cmd_byte_fire_p1 <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 24) 文本命令解析：UART byte stream -> line parser -> control fsm
    //==========================================================================
    uart_line_parser_v1
    #(
        .MAX_LINE_CHARS(CMD_MAX_CHARS)
    )
    u_uart_line_parser_v1
    (
        .i_clk                   (sys_clk),
        .i_rst_n                 (~sys_rst),

        .i_byte_data             (uart_rx_cmd_byte_data_p1),
        .i_byte_valid            (uart_rx_cmd_byte_fire_p1),

        .o_line_data             (cmd_line_data),
        .o_line_len              (cmd_line_len),
        .o_line_valid            (cmd_line_valid),

        .o_overflow_sticky       (cmd_line_overflow_sticky),
        .o_empty_line_seen_pulse (cmd_empty_line_seen_pulse)
    );

    demo_ctrl_fsm_v1
    #(
        .MAX_LINE_CHARS(CMD_MAX_CHARS),
        .MODE_COUNT(6)
    )
    u_demo_ctrl_fsm_v1
    (
        .i_clk                (sys_clk),
        .i_rst_n              (~sys_rst),

        .i_link_up            (channel_up),

        .i_cmd_data           (cmd_line_data),
        .i_cmd_len            (cmd_line_len),
        .i_cmd_valid          (cmd_line_valid),

        .o_osd_on             (ctrl_osd_on_sys),
        .o_menu_index         (ctrl_menu_index_sys),
        .o_active_mode        (ctrl_active_mode_sys),

        .o_resp_valid         (resp_valid),
        .i_resp_ready         (resp_ready),
        .o_resp_kind          (resp_kind),
        .o_resp_err_code      (resp_err_code),
        .o_resp_link_up       (resp_link_up),
        .o_resp_osd_on        (resp_osd_on),
        .o_resp_menu_index    (resp_menu_index),
        .o_resp_active_mode   (resp_active_mode),

        .o_unknown_cmd_sticky (fsm_unknown_cmd_sticky),
        .o_bad_arg_sticky     (fsm_bad_arg_sticky),
        .o_linkdown_cmd_sticky(fsm_linkdown_cmd_sticky),
        .o_cmd_while_busy_sticky(fsm_cmd_while_busy_sticky)
    );

    //==========================================================================
    // 25) 响应格式化：structured response -> UART TX text response
    //==========================================================================
    uart_resp_formatter_v1
    #(
        .MAX_RESP_CHARS(RESP_MAX_CHARS)
    )
    u_uart_resp_formatter_v1
    (
        .i_clk               (sys_clk),
        .i_rst_n             (~sys_rst),

        .i_resp_valid        (resp_valid),
        .o_resp_ready        (resp_ready),
        .i_resp_kind         (resp_kind),
        .i_resp_err_code     (resp_err_code),
        .i_resp_link_up      (resp_link_up),
        .i_resp_osd_on       (resp_osd_on),
        .i_resp_menu_index   (resp_menu_index),
        .i_resp_active_mode  (resp_active_mode),

        .o_byte_data         (resp_uart_byte),
        .o_byte_valid        (resp_uart_byte_valid),
        .i_byte_ready        (uart_tx_ready),

        .o_busy              (resp_fmt_busy),
        .o_dbg_len           (resp_fmt_dbg_len),
        .o_overflow_sticky   (resp_fmt_overflow_sticky)
    );

    uart_tx_byte_v1
    #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    )
    u_uart_tx_byte_v1
    (
        .i_clk          (sys_clk),
        .i_rst_n        (~sys_rst),

        .i_byte_data    (resp_uart_byte),
        .i_byte_valid   (resp_uart_byte_valid),
        .o_byte_ready   (uart_tx_ready),

        .o_uart_tx      (tx_o),
        .o_busy         (uart_tx_busy)
    );

    //==========================================================================
    // 26) OSD / Pattern / Menu 同步到 pixel_clk
    //==========================================================================
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            osd_enable_meta      <= 1'b0;
            osd_enable_pclk      <= 1'b0;
            pattern_mode_meta    <= 3'd0;
            pattern_mode_pending <= 3'd0;
            menu_index_meta      <= 3'd0;
            menu_index_pclk      <= 3'd0;
        end
        else begin
            osd_enable_meta      <= ctrl_osd_on_sys;
            osd_enable_pclk      <= osd_enable_meta;

            pattern_mode_meta    <= ctrl_active_mode_sys;
            pattern_mode_pending <= pattern_mode_meta;

            menu_index_meta      <= ctrl_menu_index_sys;
            menu_index_pclk      <= menu_index_meta;
        end
    end

    //==========================================================================
    // 27) Pattern mode 在帧边界生效，并映射到 testpattern 的 I_mode
    //==========================================================================
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            pattern_mode_active <= 3'd0;
            tp_mode_active      <= 3'b000;
            tp_single_r_active  <= 8'd0;
            tp_single_g_active  <= 8'd255;
            tp_single_b_active  <= 8'd0;
        end
        else begin
            if (tp_frame_start) begin
                pattern_mode_active <= pattern_mode_pending;

                case (pattern_mode_pending)
                    3'd0: begin
                        // COLORBAR
                        tp_mode_active     <= 3'b000;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd255;
                        tp_single_b_active <= 8'd0;
                    end

                    3'd1: begin
                        // NETGRID
                        tp_mode_active     <= 3'b001;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd0;
                        tp_single_b_active <= 8'd0;
                    end

                    3'd2: begin
                        // GRAY
                        tp_mode_active     <= 3'b010;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd0;
                        tp_single_b_active <= 8'd0;
                    end

                    3'd3: begin
                        // BWSQUARE
                        tp_mode_active     <= 3'b011;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd0;
                        tp_single_b_active <= 8'd0;
                    end

                    3'd4: begin
                        // RED
                        tp_mode_active     <= 3'b111;
                        tp_single_r_active <= 8'd255;
                        tp_single_g_active <= 8'd0;
                        tp_single_b_active <= 8'd0;
                    end

                    3'd5: begin
                        // GREEN
                        tp_mode_active     <= 3'b111;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd255;
                        tp_single_b_active <= 8'd0;
                    end

                    default: begin
                        tp_mode_active     <= 3'b000;
                        tp_single_r_active <= 8'd0;
                        tp_single_g_active <= 8'd255;
                        tp_single_b_active <= 8'd0;
                    end
                endcase
            end
        end
    end

    //==========================================================================
    // 28) 菜单 OSD 叠加
    //==========================================================================
    osd_menu_overlay_v1
    #(
        .ACTIVE_H_START (16'd260),
        .ACTIVE_V_START (16'd25),
        .ACTIVE_W       (16'd1280),
        .ACTIVE_H       (16'd720),
        .BOX_W          (16'd360),
        .BOX_H          (16'd200)
    )
    u_osd_menu_overlay_v1
    (
        .i_clk          (pixel_clk),
        .i_rst_n        (pixel_rst_n),

        .i_osd_enable   (osd_enable_pclk),
        .i_menu_index   (menu_index_pclk),

        .i_h_cnt        (tp_h_cnt),
        .i_v_cnt        (tp_v_cnt),
        .i_de           (tp_de),

        .i_base_rgb     (base_rgb),

        .o_rgb          (osd_rgb),
        .o_in_box       (osd_in_box)
    );

    //==========================================================================
    // 29) pixel 域：blink / prefill / VS 锁流
    //==========================================================================
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            tp_vs_d               <= 1'b0;
            blink_cnt             <= 8'd0;

            channel_up_meta_pclk  <= 1'b0;
            channel_up_pclk       <= 1'b0;
            channel_up_pclk_d     <= 1'b0;

            rx_prefill_cnt        <= 16'd0;
            rx_read_enable_pclk   <= 1'b0;
            rx_stream_enable_pclk <= 1'b0;

            rx_sym_vs_d           <= 1'b0;
        end
        else begin
            tp_vs_d <= tp_vs;
            if (tp_vs_d && !tp_vs)
                blink_cnt <= blink_cnt + 8'd1;

            channel_up_meta_pclk <= channel_up;
            channel_up_pclk      <= channel_up_meta_pclk;
            channel_up_pclk_d    <= channel_up_pclk;

            rx_sym_vs_d <= rx_sym_vs;

            if (!channel_up_pclk) begin
                rx_prefill_cnt        <= 16'd0;
                rx_read_enable_pclk   <= 1'b0;
                rx_stream_enable_pclk <= 1'b0;
            end
            else begin
                if (!rx_read_enable_pclk) begin
                    if (rx_prefill_cnt < RX_PREFILL_CYCLES)
                        rx_prefill_cnt <= rx_prefill_cnt + 16'd1;
                    else
                        rx_read_enable_pclk <= 1'b1;
                end

                if (rx_read_enable_pclk && rx_vs_rise_pclk)
                    rx_stream_enable_pclk <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 30) FIFO 实例
    //==========================================================================

    // TX_VIDEO async FIFO
    fifo_top_tx36x4096 u_fifo_top_tx36x4096
    (
        .Data           (tx_video_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (pixel_clk),
        .RdClk          (sys_clk),
        .WrEn           (tx_video_fifo_wr_en),
        .RdEn           (tx_video_fifo_rd_en),
        .Rnum           (tx_video_fifo_rnum),
        .Almost_Empty   (),
        .Almost_Full    (),
        .Q              (tx_video_fifo_dout),
        .Empty          (tx_video_fifo_empty),
        .Full           (tx_video_fifo_full)
    );

    // RX_VIDEO async FIFO
    fifo_top_rx36x4096 u_fifo_top_rx36x4096
    (
        .Data           (rx_video_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (sys_clk),
        .RdClk          (pixel_clk),
        .WrEn           (rx_video_fifo_wr_en),
        .RdEn           (rx_video_fifo_rd_en),
        .Almost_Empty   (),
        .Almost_Full    (),
        .Q              (rx_video_fifo_dout),
        .Empty          (rx_video_fifo_empty),
        .Full           (rx_video_fifo_full)
    );

    // TX_CTRL sync FIFO
    sync_fifo_fwft_v1
    #(
        .DATA_W (32),
        .DEPTH  (CTRL_FIFO_DEPTH),
        .ADDR_W (CTRL_FIFO_AW)
    )
    u_tx_ctrl_fifo
    (
        .i_clk      (sys_clk),
        .i_rst_n    (~sys_rst),

        .i_wr_en    (tx_ctrl_fifo_wr_en),
        .i_din      (tx_ctrl_fifo_din),
        .o_full     (tx_ctrl_fifo_full),

        .i_rd_en    (tx_ctrl_fifo_rd_en),
        .o_dout     (tx_ctrl_fifo_dout),
        .o_empty    (tx_ctrl_fifo_empty),
        .o_count    ()
    );

    // RX_CTRL sync FIFO
    sync_fifo_fwft_v1
    #(
        .DATA_W (32),
        .DEPTH  (CTRL_FIFO_DEPTH),
        .ADDR_W (CTRL_FIFO_AW)
    )
    u_rx_ctrl_fifo
    (
        .i_clk      (sys_clk),
        .i_rst_n    (~sys_rst),

        .i_wr_en    (rx_ctrl_fifo_wr_en),
        .i_din      (rx_ctrl_fifo_din),
        .o_full     (rx_ctrl_fifo_full),

        .i_rd_en    (rx_ctrl_fifo_rd_en),
        .o_dout     (rx_ctrl_fifo_dout),
        .o_empty    (rx_ctrl_fifo_empty),
        .o_count    ()
    );

    //==========================================================================
    // 31) HDMI 输出
    //==========================================================================
    assign O_adv7513_clk  = pixel_clk;
    assign O_adv7513_vs   = hdmi_vs;
    assign O_adv7513_hs   = hdmi_hs;
    assign O_adv7513_de   = hdmi_de;
    assign O_adv7513_data = osd_rgb;

endmodule