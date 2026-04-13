`timescale 1 ns / 1 ps

/*********************************************************************************
* Version      : RL8B10B_TOP_V2.0.0
* Date         : 2026-03-24
* Description  :
*   1) 基于官方参考工程 proven 的 clock/reset 骨架，切换到 Streaming 接口。
*   2) 适用前提：
*      - Dataflow Mode      : Duplex
*      - Interface          : Streaming
*      - Flow Control       : None
*      - CRC                : Off
*      - Scrambler          : Off（建议本版先关）
*      - Number of Lanes    : 1
*      - Data Width Per Lane: 4
*      - Loopback Mode      : LB_NES
*   3) 顶层只保留最小 bring-up 逻辑：
*      - 连续计数发送
*      - 接收侧自同步递增比较
*      - hard_err / soft_err 监控
*      - test_pass 输出
*
* Notes :
*   Streaming 接口没有 user_tx_last/user_tx_strb/user_rx_last/user_rx_strb，
*   只看 valid/ready/data。
*********************************************************************************/

module top
(
    input           osc_clk_i,          // 50M
    input           resetn_i,           // low-active

    output          sfp1_tx_disable_o,
    output          sfp2_tx_disable_o,

    input           rx_i,               // 本版本未使用，保留端口
    output          tx_o,               // 本版本未使用，固定拉高

    output [3:0]    test_o,
    output [3:0]    led_o
);

//==============================================================================
// 0) 参数定义
//==============================================================================
`define LANE_WIDTH      1
`define LANE_DATA_WIDTH 32

parameter DATA_WIDTH      = `LANE_DATA_WIDTH * `LANE_WIDTH;
parameter LANE_WIDTH      = `LANE_WIDTH;
parameter LANE_DATA_WIDTH = `LANE_DATA_WIDTH;

// 通过多少个连续有效 beat 后，认为链路和数据流已经稳定
parameter PASS_VALID_CNT  = 16'd256;

// 版本号：V2.0.0 -> 0x02000000
localparam [31:0] TOP_VERSION = 32'h0200_0000;

//==============================================================================
// 1) 用户接口信号（Streaming）
//==============================================================================
wire [DATA_WIDTH-1:0] user_tx_data  /* synthesis syn_keep=1 */;
wire                  user_tx_valid /* synthesis syn_keep=1 */;
wire                  user_tx_ready /* synthesis syn_keep=1 */;

wire [DATA_WIDTH-1:0] user_rx_data  /* synthesis syn_keep=1 */;
wire                  user_rx_valid /* synthesis syn_keep=1 */;

wire                  hard_err;
wire                  soft_err;

wire                  channel_up /* synthesis syn_keep=1 */;
wire [LANE_WIDTH-1:0] lane_up    /* synthesis syn_keep=1 */;

//==============================================================================
// 2) 时钟 / 复位 / SerDes 状态
//==============================================================================
wire                  sys_clk     /* synthesis syn_keep=1 */;
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

//==============================================================================
// 3) 最小 TX/RX 测试逻辑
//==============================================================================
reg  [31:0] tx_counter;
reg         channel_up_1d;
reg         test_pass;

// RX 侧自同步检查
reg         rx_seen;
reg  [31:0] rx_expected;
reg  [31:0] rx_last_data;
reg  [15:0] rx_valid_count;
reg  [15:0] rx_good_count;
reg  [15:0] rx_bad_count;
reg         rx_activity_toggle;

// sticky 错误
reg         hard_err_seen;
reg         soft_err_seen;
reg         rx_mismatch_seen;

//==============================================================================
// 4) 顶层固定连接
//==============================================================================
assign sfp1_tx_disable_o = 1'b0;
assign sfp2_tx_disable_o = 1'b0;

// UART 在本版本未使用，固定输出高
assign tx_o              = 1'b1;
assign test_o            = 4'd0;

// LED 定义：
// LED0: cfg PLL lock
// LED1: GT PLL lock
// LED2: channel_up
// LED3: test_pass
assign led_o[0]          = cfg_pll_lock;
assign led_o[1]          = gt_pll_ok;
assign led_o[2]          = channel_up_1d;
assign led_o[3]          = test_pass;

// 保持与官方参考 top 一致的关键骨架
assign sys_clk           = gt_pcs_tx_clk[0];

// 不通过寄存器软件控制 GT/PCS 复位，全部固定为 0
assign gt_reset          = 1'b0;
assign gt_pcs_tx_reset   = 1'b0;
assign gt_pcs_rx_reset   = 1'b0;

// 删除 reg_rst，直接使用官方参考思路的精简版
assign sys_reset_gen     = cfg_pll_lock & gt_pll_ok & resetn_i;

//==============================================================================
// 5) 配置时钟与复位生成
//==============================================================================
Gowin_PLL u_Gowin_PLL
(
    .reset      ( !resetn_i     ),
    .lock       ( cfg_pll_lock  ),
    .clkout0    ( cfg_clk       ),
    .clkin      ( osc_clk_i     )
);

reset_gen u1_reset_gen
(
    .i_clk1     ( cfg_clk       ),
    .i_lock     ( cfg_pll_lock  ),
    .o_rst1     ( cfg_rst       )
);

reset_gen u2_reset_gen
(
    .i_clk1     ( sys_clk       ),
    .i_lock     ( sys_reset_gen ),
    .o_rst1     ( sys_rst       )
);

//==============================================================================
// 6) 最小 Streaming 发送器
//------------------------------------------------------------------------------
// Streaming 只需要 valid/ready/data。
// 当 channel_up 建立且 sys_reset 释放后，持续发送 32bit 计数数据。
// 只有在 valid&ready 时，tx_counter 才递增。
//==============================================================================
wire tx_active;
wire tx_fire;

assign tx_active     = channel_up_1d & (~sys_reset);
assign tx_fire       = user_tx_valid & user_tx_ready;

assign user_tx_valid = tx_active;
assign user_tx_data  = tx_counter;

always @(posedge sys_clk) begin
    if (sys_reset) begin
        tx_counter <= 32'd0;
    end
    else if (!channel_up_1d) begin
        tx_counter <= 32'd0;
    end
    else if (tx_fire) begin
        tx_counter <= tx_counter + 32'd1;
    end
end

//==============================================================================
// 7) 最小 Streaming RX 检查器
//------------------------------------------------------------------------------
// 做法：
// 1. 第一次看到 user_rx_valid 时，不立即判错，只把当前值作为同步起点。
// 2. 后续每次 user_rx_valid，都和“期望值”比较。
// 3. 比较后用当前收到的数据重新同步 expected，便于快速恢复对齐。
// 4. test_pass 条件：
//    - channel_up 已建立
//    - 收到不少于 PASS_VALID_CNT 个有效 beat
//    - 没有 hard_err / soft_err
//    - 没有递增比较错误
//==============================================================================
always @(posedge sys_clk) begin
    if (sys_reset) begin
        channel_up_1d      <= 1'b0;
        rx_seen            <= 1'b0;
        rx_expected        <= 32'd0;
        rx_last_data       <= 32'd0;
        rx_valid_count     <= 16'd0;
        rx_good_count      <= 16'd0;
        rx_bad_count       <= 16'd0;
        rx_activity_toggle <= 1'b0;
        test_pass          <= 1'b0;

        hard_err_seen      <= 1'b0;
        soft_err_seen      <= 1'b0;
        rx_mismatch_seen   <= 1'b0;
    end
    else begin
        channel_up_1d <= channel_up;

        if (!channel_up_1d) begin
            rx_seen            <= 1'b0;
            rx_expected        <= 32'd0;
            rx_last_data       <= 32'd0;
            rx_valid_count     <= 16'd0;
            rx_good_count      <= 16'd0;
            rx_bad_count       <= 16'd0;
            rx_activity_toggle <= 1'b0;
            test_pass          <= 1'b0;

            hard_err_seen      <= 1'b0;
            soft_err_seen      <= 1'b0;
            rx_mismatch_seen   <= 1'b0;
        end
        else begin
            if (hard_err)
                hard_err_seen <= 1'b1;

            if (soft_err)
                soft_err_seen <= 1'b1;

            if (user_rx_valid) begin
                rx_valid_count     <= rx_valid_count + 16'd1;
                rx_last_data       <= user_rx_data;
                rx_activity_toggle <= ~rx_activity_toggle;

                if (!rx_seen) begin
                    rx_seen     <= 1'b1;
                    rx_expected <= user_rx_data + 32'd1;
                end
                else begin
                    if (user_rx_data == rx_expected) begin
                        rx_good_count <= rx_good_count + 16'd1;
                    end
                    else begin
                        rx_bad_count      <= rx_bad_count + 16'd1;
                        rx_mismatch_seen  <= 1'b1;
                    end

                    rx_expected <= user_rx_data + 32'd1;
                end
            end

            if (channel_up_1d &&
                rx_seen &&
                (rx_valid_count >= PASS_VALID_CNT) &&
                !hard_err_seen &&
                !soft_err_seen &&
                !rx_mismatch_seen) begin
                test_pass <= 1'b1;
            end
        end
    end
end

//==============================================================================
// 8) ILA 观测信号（统一 ila_ 前缀）
//==============================================================================
(* keep = "true" *) wire [31:0] ila_top_version       = TOP_VERSION;

(* keep = "true" *) wire        ila_cfg_clk           = cfg_clk;
(* keep = "true" *) wire        ila_cfg_pll_lock      = cfg_pll_lock;
(* keep = "true" *) wire        ila_cfg_rst           = cfg_rst;

(* keep = "true" *) wire        ila_sys_clk           = sys_clk;
(* keep = "true" *) wire        ila_sys_reset_gen     = sys_reset_gen;
(* keep = "true" *) wire        ila_sys_rst           = sys_rst;
(* keep = "true" *) wire        ila_sys_reset         = sys_reset;
(* keep = "true" *) wire        ila_link_reset        = link_reset;

(* keep = "true" *) wire        ila_gt_reset          = gt_reset;
(* keep = "true" *) wire        ila_gt_pcs_tx_reset   = gt_pcs_tx_reset;
(* keep = "true" *) wire        ila_gt_pcs_rx_reset   = gt_pcs_rx_reset;
(* keep = "true" *) wire        ila_gt_pll_ok         = gt_pll_ok;

(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_gt_pcs_tx_clk    = gt_pcs_tx_clk;
(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_gt_pcs_rx_clk    = gt_pcs_rx_clk;
(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_gt_rx_pma_lock   = gt_rx_pma_lock;
(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_gt_rx_k_lock     = gt_rx_k_lock;
(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_gt_rx_align_link = gt_rx_align_link;

(* keep = "true" *) wire        ila_channel_up        = channel_up;
(* keep = "true" *) wire [LANE_WIDTH-1:0] ila_lane_up = lane_up;
(* keep = "true" *) wire        ila_channel_up_1d     = channel_up_1d;

(* keep = "true" *) wire [DATA_WIDTH-1:0] ila_user_tx_data  = user_tx_data;
(* keep = "true" *) wire                  ila_user_tx_valid = user_tx_valid;
(* keep = "true" *) wire                  ila_user_tx_ready = user_tx_ready;
(* keep = "true" *) wire                  ila_tx_fire       = tx_fire;
(* keep = "true" *) wire [31:0]           ila_tx_counter    = tx_counter;

(* keep = "true" *) wire [DATA_WIDTH-1:0] ila_user_rx_data  = user_rx_data;
(* keep = "true" *) wire                  ila_user_rx_valid = user_rx_valid;

(* keep = "true" *) wire                  ila_hard_err           = hard_err;
(* keep = "true" *) wire                  ila_soft_err           = soft_err;
(* keep = "true" *) wire                  ila_hard_err_seen      = hard_err_seen;
(* keep = "true" *) wire                  ila_soft_err_seen      = soft_err_seen;
(* keep = "true" *) wire                  ila_rx_mismatch_seen   = rx_mismatch_seen;

(* keep = "true" *) wire                  ila_rx_seen            = rx_seen;
(* keep = "true" *) wire [31:0]           ila_rx_expected        = rx_expected;
(* keep = "true" *) wire [31:0]           ila_rx_last_data       = rx_last_data;
(* keep = "true" *) wire [15:0]           ila_rx_valid_count     = rx_valid_count;
(* keep = "true" *) wire [15:0]           ila_rx_good_count      = rx_good_count;
(* keep = "true" *) wire [15:0]           ila_rx_bad_count       = rx_bad_count;
(* keep = "true" *) wire                  ila_rx_activity_toggle = rx_activity_toggle;
(* keep = "true" *) wire                  ila_test_pass          = test_pass;

//==============================================================================
// 9) SerDes_Top 实例（Streaming 端口）
//==============================================================================
SerDes_Top u_SerDes_Top
(
    .RoraLink_8B10B_Top_link_reset_o        ( link_reset         ),
    .RoraLink_8B10B_Top_sys_reset_o         ( sys_reset          ),
    .RoraLink_8B10B_Top_user_tx_ready_o     ( user_tx_ready      ),
    .RoraLink_8B10B_Top_user_rx_data_o      ( user_rx_data       ),
    .RoraLink_8B10B_Top_user_rx_valid_o     ( user_rx_valid      ),
    .RoraLink_8B10B_Top_hard_err_o          ( hard_err           ),
    .RoraLink_8B10B_Top_soft_err_o          ( soft_err           ),
    .RoraLink_8B10B_Top_channel_up_o        ( channel_up         ),
    .RoraLink_8B10B_Top_lane_up_o           ( lane_up            ),
    .RoraLink_8B10B_Top_gt_pcs_tx_clk_o     ( gt_pcs_tx_clk      ),
    .RoraLink_8B10B_Top_gt_pcs_rx_clk_o     ( gt_pcs_rx_clk      ),
    .RoraLink_8B10B_Top_gt_pll_lock_o       ( gt_pll_ok          ),
    .RoraLink_8B10B_Top_gt_rx_align_link_o  ( gt_rx_align_link   ),
    .RoraLink_8B10B_Top_gt_rx_pma_lock_o    ( gt_rx_pma_lock     ),
    .RoraLink_8B10B_Top_gt_rx_k_lock_o      ( gt_rx_k_lock       ),
    .RoraLink_8B10B_Top_user_clk_i          ( sys_clk            ),
    .RoraLink_8B10B_Top_init_clk_i          ( cfg_clk            ),
    .RoraLink_8B10B_Top_reset_i             ( sys_rst            ),
    .RoraLink_8B10B_Top_user_pll_locked_i   ( gt_pll_ok          ),
    .RoraLink_8B10B_Top_user_tx_data_i      ( user_tx_data       ),
    .RoraLink_8B10B_Top_user_tx_valid_i     ( user_tx_valid      ),
    .RoraLink_8B10B_Top_gt_reset_i          ( gt_reset           ),
    .RoraLink_8B10B_Top_gt_pcs_tx_reset_i   ( gt_pcs_tx_reset    ),
    .RoraLink_8B10B_Top_gt_pcs_rx_reset_i   ( gt_pcs_rx_reset    )
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