`timescale 1ns / 1ps

/*********************************************************************************
* Module       : stream_mux_qos_v1
* Description  :
*   32-bit 双路流复用器，输出到单路 8b10b streaming TX
*
* Inputs:
*   - video stream from TX_VIDEO_FIFO
*   - ctrl  stream from TX_CTRL_FIFO
*
* Policy:
*   1) 默认 ctrl 高优先级
*   2) 若 video FIFO 水位达到高水位，则强制切到视频优先
*   3) 视频优先时，连续发送一小段 burst，再重新仲裁
*
* FIFO assumptions:
*   - FWFT / Show-Ahead
*   - dout 在 empty=0 时即为当前可发送数据
*
* Notes:
*   1) 本模块不识别 payload 内容，只做调度
*   2) 建议 video FIFO 提供 Rnum，ctrl FIFO 没有也可以
*********************************************************************************/

module stream_mux_qos_v1
#(
    parameter [12:0] VIDEO_HIGH_WATERMARK = 13'd512,
    parameter [7:0]  VIDEO_BURST_LEN      = 8'd32
)
(
    input               i_clk,
    input               i_rst_n,

    // -------------------------------
    // video FIFO side
    // -------------------------------
    input      [31:0]   i_video_fifo_dout,
    input               i_video_fifo_empty,
    input      [12:0]   i_video_fifo_rnum,
    output reg          o_video_fifo_rd_en,

    // -------------------------------
    // ctrl FIFO side
    // -------------------------------
    input      [31:0]   i_ctrl_fifo_dout,
    input               i_ctrl_fifo_empty,
    output reg          o_ctrl_fifo_rd_en,

    // -------------------------------
    // mux output side
    // -------------------------------
    output reg [31:0]   o_mux_data,
    output reg          o_mux_valid,
    input               i_mux_ready,

    // -------------------------------
    // debug
    // -------------------------------
    output reg          o_dbg_sel_video,
    output reg          o_dbg_sel_ctrl,
    output reg [7:0]    o_dbg_video_burst_left,
    output reg          o_dbg_video_force_mode
);

    localparam [1:0]
        S_ARB   = 2'd0,
        S_VIDEO = 2'd1,
        S_CTRL  = 2'd2;

    reg [1:0] r_state;
    reg [7:0] r_video_burst_left;

    wire w_video_force = (i_video_fifo_rnum >= VIDEO_HIGH_WATERMARK);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state               <= S_ARB;
            r_video_burst_left    <= 8'd0;

            o_video_fifo_rd_en    <= 1'b0;
            o_ctrl_fifo_rd_en     <= 1'b0;

            o_mux_data            <= 32'd0;
            o_mux_valid           <= 1'b0;

            o_dbg_sel_video       <= 1'b0;
            o_dbg_sel_ctrl        <= 1'b0;
            o_dbg_video_burst_left<= 8'd0;
            o_dbg_video_force_mode<= 1'b0;
        end
        else begin
            o_video_fifo_rd_en <= 1'b0;
            o_ctrl_fifo_rd_en  <= 1'b0;
            o_mux_valid        <= 1'b0;

            o_dbg_sel_video        <= 1'b0;
            o_dbg_sel_ctrl         <= 1'b0;
            o_dbg_video_burst_left <= r_video_burst_left;
            o_dbg_video_force_mode <= w_video_force;

            case (r_state)
                // ----------------------------------------------------------
                // 仲裁状态
                // ----------------------------------------------------------
                S_ARB: begin
                    if (w_video_force && !i_video_fifo_empty) begin
                        r_state            <= S_VIDEO;
                        r_video_burst_left <= VIDEO_BURST_LEN;
                    end
                    else if (!i_ctrl_fifo_empty) begin
                        r_state <= S_CTRL;
                    end
                    else if (!i_video_fifo_empty) begin
                        r_state <= S_VIDEO;
                        r_video_burst_left <= 8'd1;
                    end
                end

                // ----------------------------------------------------------
                // 发送视频
                // ----------------------------------------------------------
                S_VIDEO: begin
                    if (!i_video_fifo_empty) begin
                        o_mux_data      <= i_video_fifo_dout;
                        o_mux_valid     <= 1'b1;
                        o_dbg_sel_video <= 1'b1;

                        if (i_mux_ready) begin
                            o_video_fifo_rd_en <= 1'b1;

                            if (r_video_burst_left > 8'd1) begin
                                r_video_burst_left <= r_video_burst_left - 8'd1;

                                // burst 期间如果视频 FIFO 仍然很高，允许续 burst
                                if ((r_video_burst_left == 8'd2) && w_video_force)
                                    r_video_burst_left <= VIDEO_BURST_LEN;
                            end
                            else begin
                                r_video_burst_left <= 8'd0;
                                r_state            <= S_ARB;
                            end
                        end
                    end
                    else begin
                        r_video_burst_left <= 8'd0;
                        r_state            <= S_ARB;
                    end
                end

                // ----------------------------------------------------------
                // 发送用户数据
                // ----------------------------------------------------------
                S_CTRL: begin
                    // 如果视频 FIFO 已经很高，允许抢占 ctrl，先救视频
                    if (w_video_force && !i_video_fifo_empty) begin
                        r_state            <= S_VIDEO;
                        r_video_burst_left <= VIDEO_BURST_LEN;
                    end
                    else if (!i_ctrl_fifo_empty) begin
                        o_mux_data     <= i_ctrl_fifo_dout;
                        o_mux_valid    <= 1'b1;
                        o_dbg_sel_ctrl <= 1'b1;

                        if (i_mux_ready) begin
                            o_ctrl_fifo_rd_en <= 1'b1;
                            r_state           <= S_ARB;
                        end
                    end
                    else begin
                        r_state <= S_ARB;
                    end
                end

                default: begin
                    r_state            <= S_ARB;
                    r_video_burst_left <= 8'd0;
                end
            endcase
        end
    end

endmodule