`timescale 1ns / 1ps

/*********************************************************************************
* Module       : top
* Style tag    : top_full_timing_stream_uart_v1
* Description  :
*   720p60 full-timing video stream + high-priority UART user-data stream
*
* Video path:
*   local color bar (tp_vs/tp_hs/tp_de/tp_rgb)
*      -> video_symbol_packer_v1
*      -> TX_VIDEO async FIFO
*      -> stream_mux_qos_v1
*      -> RoraLink 8b10b streaming
*      -> stream_demux_v1
*      -> RX_VIDEO async FIFO
*      -> video_symbol_unpacker_v1
*      -> HDMI
*
* UART user-data path:
*   rx_i (UART RX)
*      -> uart_rx_byte_v1
*      -> uart_word_packer_v1
*      -> TX_CTRL sync FIFO
*      -> stream_mux_qos_v1
*      -> RoraLink 8b10b streaming
*      -> stream_demux_v1
*      -> RX_CTRL sync FIFO
*      -> uart_word_unpacker_v1
*      -> uart_tx_byte_v1
*      -> tx_o (UART TX)
*
* Notes:
*   1) pixel_clk = 74.25MHz
*   2) sys_clk 假设约为 78.125MHz（line rate 3.125Gbps / 40）
*   3) UART 默认 115200 baud，对应 UART_CLKS_PER_BIT = 678
*   4) HDMI 在未锁流前输出本地 720p 黑屏 timing
*   5) 用户数据默认高优先级，但带视频高水位保护，避免视频被饿死
*********************************************************************************/

module top
(
    input           osc_clk_i,
    input           resetn_i,

    output          sfp1_tx_disable_o,
    output          sfp2_tx_disable_o,

    input           rx_i,               // UART RX
    output          tx_o,               // UART TX

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

    // RX 视频启动前预填充时间（pixel_clk 周期）
    localparam [15:0] RX_PREFILL_CYCLES = 16'd1024;

    // UART 参数（sys_clk≈78.125MHz, baud=115200 -> 78125000/115200≈678）
    localparam integer UART_CLKS_PER_BIT = 678;

    // 控制 FIFO 深度参数
    localparam integer CTRL_FIFO_DEPTH  = 64;
    localparam integer CTRL_FIFO_AW     = 6;

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
    wire                  sys_clk;
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
    wire        pixel_clk;       // 74.25MHz
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

    // RX_VIDEO async FIFO（沿用你现有 36-bit FIFO）
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
    // 9) RX: UART control stream -> uart_word_unpacker -> UART TX
    //==========================================================================
    wire [7:0]  uart_tx_byte_from_link;
    wire        uart_tx_byte_valid_from_link;
    wire        uart_tx_ready;

    wire [7:0]  uart_rx_link_last_seq;
    wire [7:0]  uart_rx_link_expected_seq;
    wire        uart_rx_type_err_sticky;
    wire        uart_rx_channel_err_sticky;
    wire        uart_rx_crc_err_sticky;
    wire        uart_rx_seq_err_sticky;

    wire        uart_tx_busy;

    //==========================================================================
    // 10) pixel 域流控 / 锁流
    //==========================================================================
    reg channel_up_meta_pclk  = 1'b0;
    reg channel_up_pclk       = 1'b0;
    reg channel_up_pclk_d     = 1'b0;

    reg [15:0] rx_prefill_cnt = 16'd0;
    reg        rx_read_enable_pclk   = 1'b0;
    reg        rx_stream_enable_pclk = 1'b0;

    reg        rx_sym_vs_d = 1'b0;

    wire channel_up_rise_pclk;
    wire channel_down_pulse_pclk;
    wire rx_vs_rise_pclk;

    assign channel_up_rise_pclk    = (~channel_up_pclk_d) & channel_up_pclk;
    assign channel_down_pulse_pclk = channel_up_pclk_d & (~channel_up_pclk);
    assign rx_vs_rise_pclk         = (~rx_sym_vs_d) & rx_sym_vs & rx_sym_valid;

    // 只有预填充完成后才开始消费 RX_VIDEO FIFO
    wire rx_video_ready_pclk;
    assign rx_video_ready_pclk = rx_read_enable_pclk;

    //==========================================================================
    // 11) HDMI 输出选择
    //==========================================================================
    wire        hdmi_vs;
    wire        hdmi_hs;
    wire        hdmi_de;
    wire [23:0] hdmi_rgb;

    // 未锁流前：输出本地 720p timing + 黑屏
    // 锁流后：输出返回 timing + rgb
    assign hdmi_vs  = rx_stream_enable_pclk ? rx_sym_vs  : tp_vs;
    assign hdmi_hs  = rx_stream_enable_pclk ? rx_sym_hs  : tp_hs;
    assign hdmi_de  = rx_stream_enable_pclk ? rx_sym_de  : tp_de;
    assign hdmi_rgb = rx_stream_enable_pclk ? rx_sym_rgb : 24'h000000;

    //==========================================================================
    // 12) 固定连接 / LED / TEST
    //==========================================================================
    assign sfp1_tx_disable_o = 1'b0;
    assign sfp2_tx_disable_o = 1'b0;

    assign led_o[0] = cfg_pll_lock;
    assign led_o[1] = gt_pll_ok;
    assign led_o[2] = channel_up;
    assign led_o[3] = rx_stream_enable_pclk;

    assign test_o[0] = tx_video_overflow_sticky;
    assign test_o[1] = rx_stream_underflow_sticky;
    assign test_o[2] = tx_ctrl_overflow_sticky_from_packer;
    assign test_o[3] = uart_rx_crc_err_sticky | uart_rx_seq_err_sticky |
                       uart_rx_type_err_sticky | uart_rx_channel_err_sticky;

    //==========================================================================
    // 13) 时钟 / 复位
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
        .clkout0    ( pixel_clk       ),   // 74.25MHz
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
    // 14) ADV7513 / 本地 720p 测试图
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
        .I_mode      (3'b000),
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

    //==========================================================================
    // 15) SerDes_Top（streaming mode）
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
    // 16) 视频发送端：打包完整 timing -> TX_VIDEO FIFO
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
    // 17) UART 发送到链路：UART RX -> 控制字 -> TX_CTRL FIFO
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
    // 18) TX 复用：ctrl 高优先级 + 视频高水位保护
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
    // 19) RX 解复用：视频 -> RX_VIDEO FIFO，控制 -> RX_CTRL FIFO
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
    // 20) RX 视频恢复：RX_VIDEO FIFO -> HDMI
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
    // 21) RX 控制恢复：RX_CTRL FIFO -> UART TX
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

        .i_byte_ready        (uart_tx_ready),
        .o_byte_data         (uart_tx_byte_from_link),
        .o_byte_valid        (uart_tx_byte_valid_from_link),

        .o_dbg_last_seq      (uart_rx_link_last_seq),
        .o_dbg_expected_seq  (uart_rx_link_expected_seq),

        .o_type_err_sticky   (uart_rx_type_err_sticky),
        .o_channel_err_sticky(uart_rx_channel_err_sticky),
        .o_crc_err_sticky    (uart_rx_crc_err_sticky),
        .o_seq_err_sticky    (uart_rx_seq_err_sticky)
    );

    uart_tx_byte_v1
    #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    )
    u_uart_tx_byte_v1
    (
        .i_clk          (sys_clk),
        .i_rst_n        (~sys_rst),

        .i_byte_data    (uart_tx_byte_from_link),
        .i_byte_valid   (uart_tx_byte_valid_from_link),
        .o_byte_ready   (uart_tx_ready),

        .o_uart_tx      (tx_o),
        .o_busy         (uart_tx_busy)
    );

    //==========================================================================
    // 22) pixel 域：预填充 + VS 锁流
    //==========================================================================
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            channel_up_meta_pclk   <= 1'b0;
            channel_up_pclk        <= 1'b0;
            channel_up_pclk_d      <= 1'b0;

            rx_prefill_cnt         <= 16'd0;
            rx_read_enable_pclk    <= 1'b0;
            rx_stream_enable_pclk  <= 1'b0;

            rx_sym_vs_d            <= 1'b0;
        end
        else begin
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
    // 23) FIFO 实例
    //==========================================================================

    // -------------------------------
    // TX_VIDEO async FIFO（沿用你现有 36-bit FIFO）
    // -------------------------------
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

    // -------------------------------
    // RX_VIDEO async FIFO（沿用你现有 36-bit FIFO）
    // -------------------------------
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

    // -------------------------------
    // TX_CTRL sync FIFO
    // -------------------------------
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

    // -------------------------------
    // RX_CTRL sync FIFO
    // -------------------------------
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
    // 24) HDMI 输出
    //==========================================================================
    assign O_adv7513_clk  = pixel_clk;
    assign O_adv7513_vs   = hdmi_vs;
    assign O_adv7513_hs   = hdmi_hs;
    assign O_adv7513_de   = hdmi_de;
    assign O_adv7513_data = hdmi_rgb;

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


//==============================================================================
// sync_fifo_fwft_v1
// Simple synchronous FWFT / Show-Ahead FIFO
//==============================================================================
module sync_fifo_fwft_v1
#(
    parameter integer DATA_W = 32,
    parameter integer DEPTH  = 64,
    parameter integer ADDR_W = 6
)
(
    input                   i_clk,
    input                   i_rst_n,

    input                   i_wr_en,
    input      [DATA_W-1:0] i_din,
    output                  o_full,

    input                   i_rd_en,
    output     [DATA_W-1:0] o_dout,
    output                  o_empty,
    output     [ADDR_W:0]   o_count
);

    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] wptr;
    reg [ADDR_W-1:0] rptr;
    reg [ADDR_W:0]   count;

    wire do_write = i_wr_en && !o_full;
    wire do_read  = i_rd_en && !o_empty;

    assign o_empty = (count == { (ADDR_W+1){1'b0} });
    assign o_full  = (count == DEPTH[ADDR_W:0]);
    assign o_count = count;
    assign o_dout  = mem[rptr];

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            wptr  <= {ADDR_W{1'b0}};
            rptr  <= {ADDR_W{1'b0}};
            count <= {(ADDR_W+1){1'b0}};
        end
        else begin
            if (do_write) begin
                mem[wptr] <= i_din;
                wptr      <= wptr + {{(ADDR_W-1){1'b0}},1'b1};
            end

            if (do_read) begin
                rptr <= rptr + {{(ADDR_W-1){1'b0}},1'b1};
            end

            case ({do_write, do_read})
                2'b10: count <= count + {{ADDR_W{1'b0}},1'b1};
                2'b01: count <= count - {{ADDR_W{1'b0}},1'b1};
                default: count <= count;
            endcase
        end
    end

endmodule


//==============================================================================
// uart_rx_byte_v1
// UART RX -> byte pulse
//==============================================================================
module uart_rx_byte_v1
#(
    parameter integer CLKS_PER_BIT = 678
)
(
    input           i_clk,
    input           i_rst_n,
    input           i_uart_rx,

    output reg [7:0] o_byte_data,
    output reg       o_byte_valid
);

    localparam [2:0]
        S_IDLE  = 3'd0,
        S_START = 3'd1,
        S_DATA  = 3'd2,
        S_STOP  = 3'd3;

    reg [2:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;

    reg rx_meta, rx_sync;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= i_uart_rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 16'd0;
            bit_idx    <= 3'd0;
            data_reg   <= 8'd0;
            o_byte_data<= 8'd0;
            o_byte_valid <= 1'b0;
        end
        else begin
            o_byte_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (!rx_sync) begin
                        state   <= S_START;
                        clk_cnt <= (CLKS_PER_BIT >> 1);
                    end
                end

                S_START: begin
                    if (clk_cnt == 16'd0) begin
                        if (!rx_sync) begin
                            state   <= S_DATA;
                            clk_cnt <= CLKS_PER_BIT - 1;
                            bit_idx <= 3'd0;
                        end
                        else begin
                            state <= S_IDLE;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_DATA: begin
                    if (clk_cnt == 16'd0) begin
                        data_reg[bit_idx] <= rx_sync;
                        clk_cnt <= CLKS_PER_BIT - 1;

                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end
                        else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == 16'd0) begin
                        o_byte_data  <= data_reg;
                        o_byte_valid <= 1'b1;
                        state        <= S_IDLE;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


//==============================================================================
// uart_tx_byte_v1
// byte pulse -> UART TX
//==============================================================================
module uart_tx_byte_v1
#(
    parameter integer CLKS_PER_BIT = 678
)
(
    input            i_clk,
    input            i_rst_n,

    input      [7:0] i_byte_data,
    input            i_byte_valid,
    output           o_byte_ready,

    output reg       o_uart_tx,
    output reg       o_busy
);

    localparam [2:0]
        S_IDLE  = 3'd0,
        S_START = 3'd1,
        S_DATA  = 3'd2,
        S_STOP  = 3'd3;

    reg [2:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;

    assign o_byte_ready = (state == S_IDLE);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state   <= S_IDLE;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
            data_reg<= 8'd0;
            o_uart_tx <= 1'b1;
            o_busy    <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    o_uart_tx <= 1'b1;
                    o_busy    <= 1'b0;
                    clk_cnt   <= 16'd0;
                    bit_idx   <= 3'd0;

                    if (i_byte_valid) begin
                        data_reg <= i_byte_data;
                        state    <= S_START;
                        o_busy   <= 1'b1;
                        o_uart_tx<= 1'b0; // start bit
                        clk_cnt  <= CLKS_PER_BIT - 1;
                    end
                end

                S_START: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        state   <= S_DATA;
                        bit_idx <= 3'd0;
                        o_uart_tx<= data_reg[0];
                        clk_cnt <= CLKS_PER_BIT - 1;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_DATA: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        if (bit_idx == 3'd7) begin
                            state    <= S_STOP;
                            o_uart_tx <= 1'b1; // stop bit
                            clk_cnt  <= CLKS_PER_BIT - 1;
                        end
                        else begin
                            bit_idx   <= bit_idx + 3'd1;
                            o_uart_tx <= data_reg[bit_idx + 3'd1];
                            clk_cnt   <= CLKS_PER_BIT - 1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_STOP: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        state    <= S_IDLE;
                        o_uart_tx<= 1'b1;
                        o_busy   <= 1'b0;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                default: begin
                    state    <= S_IDLE;
                    o_uart_tx<= 1'b1;
                    o_busy   <= 1'b0;
                end
            endcase
        end
    end

endmodule