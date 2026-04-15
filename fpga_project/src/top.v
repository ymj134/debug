`timescale 1ns / 1ps

/*********************************************************************************
* Module       : top
* Style tag    : top_full_timing_stream_v1
* Description  :
*   720p60 full-timing stream loopback:
*
*   local color bar (tp_vs/tp_hs/tp_de/tp_rgb)
*      -> video_symbol_packer_v1
*      -> TX async FIFO
*      -> RoraLink 8b10b streaming mode
*      -> RX async FIFO
*      -> video_symbol_unpacker_v1
*      -> HDMI
*
* Notes:
*   1) pixel_clk = 74.25MHz
*   2) HDMI 在未锁流前输出本地 720p 黑屏 timing
*   3) 链路起来后，先预填充 RX FIFO，再开始消费返回流
*   4) 观察到返回流的 VS 上升沿后，切到返回 timing+rgb 显示
*********************************************************************************/

module top
(
    input           osc_clk_i,
    input           resetn_i,

    output          sfp1_tx_disable_o,
    output          sfp2_tx_disable_o,

    input           rx_i,
    output          tx_o,

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

    // RX 启动前预填充时间（pixel_clk 周期）
    localparam [15:0] RX_PREFILL_CYCLES = 16'd1024;

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
    // 4) TX: full timing symbol packer -> TX FIFO
    //==========================================================================
    wire [31:0] tx_stream_word_data;
    wire        tx_stream_word_valid;
    wire        tx_stream_overflow_sticky;

    wire [35:0] tx_fifo_din;
    wire [35:0] tx_fifo_dout;
    wire        tx_fifo_wr_en;
    wire        tx_fifo_rd_en;
    wire        tx_fifo_empty;
    wire        tx_fifo_full;

    assign tx_fifo_din   = {4'b0000, tx_stream_word_data};
    assign tx_fifo_wr_en = tx_stream_word_valid & (~tx_fifo_full);

    //==========================================================================
    // 5) RX: RX FIFO -> full timing symbol unpacker
    //==========================================================================
    wire [35:0] rx_fifo_din;
    wire [35:0] rx_fifo_dout;
    wire        rx_fifo_wr_en;
    wire        rx_fifo_rd_en;
    wire        rx_fifo_empty;
    wire        rx_fifo_full;

    wire        rx_sym_valid;
    wire        rx_sym_vs;
    wire        rx_sym_hs;
    wire        rx_sym_de;
    wire [23:0] rx_sym_rgb;
    wire        rx_stream_underflow_sticky;

    //==========================================================================
    // 6) pixel 域流控 / 锁流
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

    assign channel_up_rise_pclk   = (~channel_up_pclk_d) & channel_up_pclk;
    assign channel_down_pulse_pclk = channel_up_pclk_d & (~channel_up_pclk);
    assign rx_vs_rise_pclk        = (~rx_sym_vs_d) & rx_sym_vs & rx_sym_valid;

    //==========================================================================
    // 7) HDMI 输出选择
    //==========================================================================
    wire        hdmi_vs;
    wire        hdmi_hs;
    wire        hdmi_de;
    wire [23:0] hdmi_rgb;

    // 未锁流前：输出本地 720p timing + 黑屏
    // 锁流后：输出返回 timing + 返回 rgb
    assign hdmi_vs  = rx_stream_enable_pclk ? rx_sym_vs  : tp_vs;
    assign hdmi_hs  = rx_stream_enable_pclk ? rx_sym_hs  : tp_hs;
    assign hdmi_de  = rx_stream_enable_pclk ? rx_sym_de  : tp_de;
    assign hdmi_rgb = rx_stream_enable_pclk ? rx_sym_rgb : 24'h000000;

    //==========================================================================
    // 8) 固定连接 / LED / TEST
    //==========================================================================
    assign sfp1_tx_disable_o = 1'b0;
    assign sfp2_tx_disable_o = 1'b0;
    assign tx_o              = 1'b1;

    assign led_o[0] = cfg_pll_lock;
    assign led_o[1] = gt_pll_ok;
    assign led_o[2] = channel_up;
    assign led_o[3] = rx_stream_enable_pclk;

    assign test_o[0] = tx_stream_overflow_sticky;
    assign test_o[1] = rx_stream_underflow_sticky;
    assign test_o[2] = hard_err;
    assign test_o[3] = soft_err;

    //==========================================================================
    // 9) 时钟 / 复位
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
    // 10) ADV7513 / 本地 720p 源
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
    // 11) SerDes_Top（streaming mode）
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
    // 12) TX: full timing symbol packer
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

        .i_word_ready       (~tx_fifo_full),

        .o_word_data        (tx_stream_word_data),
        .o_word_valid       (tx_stream_word_valid),

        .o_overflow_sticky  (tx_stream_overflow_sticky)
    );

    //==========================================================================
    // 13) TX FIFO -> streaming TX
    //==========================================================================
    assign user_tx_data  = tx_fifo_dout[31:0];
    assign user_tx_valid = ~tx_fifo_empty;
    assign tx_fifo_rd_en = user_tx_ready & (~tx_fifo_empty);

    //==========================================================================
    // 14) RX streaming -> RX FIFO
    //==========================================================================
    assign rx_fifo_din   = {4'b0000, user_rx_data};
    assign rx_fifo_wr_en = user_rx_valid & (~rx_fifo_full);

    //==========================================================================
    // 15) RX unpacker
    //==========================================================================
    video_symbol_unpacker_v1 u_video_symbol_unpacker_v1
    (
        .i_clk              (pixel_clk),
        .i_rst_n            (pixel_rst_n),

        .i_fifo_dout        (rx_fifo_dout[31:0]),
        .i_fifo_empty       (rx_fifo_empty),
        .o_fifo_rd_en       (rx_fifo_rd_en),

        .i_video_ready      (rx_read_enable_pclk),

        .o_valid            (rx_sym_valid),
        .o_vs               (rx_sym_vs),
        .o_hs               (rx_sym_hs),
        .o_de               (rx_sym_de),
        .o_rgb              (rx_sym_rgb),

        .o_underflow_sticky (rx_stream_underflow_sticky)
    );

    //==========================================================================
    // 16) pixel 域：预填充 + VS 锁流
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
            // CDC
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
                // 先预填充一段时间，再开始消费 RX FIFO
                if (!rx_read_enable_pclk) begin
                    if (rx_prefill_cnt < RX_PREFILL_CYCLES)
                        rx_prefill_cnt <= rx_prefill_cnt + 16'd1;
                    else
                        rx_read_enable_pclk <= 1'b1;
                end

                // 开始消费后，观察返回视频流的 VS 上升沿，检测到后切到返回 timing
                if (rx_read_enable_pclk && rx_vs_rise_pclk)
                    rx_stream_enable_pclk <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 17) TX / RX async FIFO（沿用你现有 36bit FIFO）
    //==========================================================================
    fifo_top_tx36x4096 u_fifo_top_tx36x4096
    (
        .Data           (tx_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (pixel_clk),
        .RdClk          (sys_clk),
        .WrEn           (tx_fifo_wr_en),
        .RdEn           (tx_fifo_rd_en),
        .Rnum           (),
        .Almost_Empty   (),
        .Almost_Full    (),
        .Q              (tx_fifo_dout),
        .Empty          (tx_fifo_empty),
        .Full           (tx_fifo_full)
    );

    fifo_top_rx36x4096 u_fifo_top_rx36x4096
    (
        .Data           (rx_fifo_din),
        .Reset          (!resetn_i),
        .WrClk          (sys_clk),
        .RdClk          (pixel_clk),
        .WrEn           (rx_fifo_wr_en),
        .RdEn           (rx_fifo_rd_en),
        .Almost_Empty   (),
        .Almost_Full    (),
        .Q              (rx_fifo_dout),
        .Empty          (rx_fifo_empty),
        .Full           (rx_fifo_full)
    );

    //==========================================================================
    // 18) HDMI 输出
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