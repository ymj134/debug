`timescale 1ns / 1ps

/*********************************************************************************
* Module       : demo_ctrl_fsm_v1
* Description  :
*   Demo 控制状态机
*
* Functions:
*   1) 维护主状态：
*        - osd_on
*        - menu_index
*        - active_mode
*   2) 处理 link_up 上下沿事件
*   3) 解析 uart_line_parser_v1 输出的一整行命令
*   4) 产生结构化响应，供 uart_resp_formatter_v1 使用
*
* Menu / mode definition:
*   0 : COLORBAR
*   1 : NETGRID
*   2 : GRAY
*   3 : BWSQUARE
*   4 : RED
*   5 : GREEN
*
* Policy:
*   - MENU UP / DOWN 采用“移动即生效”
*   - link_down 时强制复位：
*       osd_on      = 0
*       menu_index  = 0
*       active_mode = 0
*   - link_up 恢复时同样复位，并先发 INFO，再自动补一条 STAT
*
* Notes:
*   1) 输入命令来自 uart_line_parser_v1，低字节在前：
*        byte0 -> [7:0], byte1 -> [15:8], ...
*   2) 本模块不直接输出 ASCII 文本
*   3) 若在 response 尚未被接收时又来了命令，会丢弃该命令并拉 sticky
*********************************************************************************/

module demo_ctrl_fsm_v1
#(
    parameter integer MAX_LINE_CHARS = 31,
    parameter integer MODE_COUNT     = 6
)
(
    input                               i_clk,
    input                               i_rst_n,

    // 当前链路状态（sys_clk 域）
    input                               i_link_up,

    // 来自 uart_line_parser_v1 的整行命令
    input       [MAX_LINE_CHARS*8-1:0]  i_cmd_data,
    input       [7:0]                   i_cmd_len,
    input                               i_cmd_valid,

    // 当前主状态输出
    output reg                          o_osd_on,
    output reg  [2:0]                   o_menu_index,
    output reg  [2:0]                   o_active_mode,

    // 结构化响应输出，给 formatter 使用
    output reg                          o_resp_valid,
    input                               i_resp_ready,
    output reg  [3:0]                   o_resp_kind,
    output reg  [3:0]                   o_resp_err_code,
    output reg                          o_resp_link_up,
    output reg                          o_resp_osd_on,
    output reg  [2:0]                   o_resp_menu_index,
    output reg  [2:0]                   o_resp_active_mode,

    // debug / sticky
    output reg                          o_unknown_cmd_sticky,
    output reg                          o_bad_arg_sticky,
    output reg                          o_linkdown_cmd_sticky,
    output reg                          o_cmd_while_busy_sticky
);

    //--------------------------------------------------------------------------
    // Response kind enum
    //--------------------------------------------------------------------------
    localparam [3:0]
        RESP_NONE             = 4'd0,
        RESP_OK_OSD           = 4'd1,
        RESP_OK_MENU          = 4'd2,
        RESP_OK_MODE          = 4'd3,
        RESP_OK_RESET         = 4'd4,
        RESP_STAT             = 4'd5,
        RESP_WARN_LINK_DOWN   = 4'd6,
        RESP_INFO_LINK_UP_RST = 4'd7,
        RESP_HELP             = 4'd8,
        RESP_ERR              = 4'd15;

    //--------------------------------------------------------------------------
    // Response error code enum
    //--------------------------------------------------------------------------
    localparam [3:0]
        ERR_NONE        = 4'd0,
        ERR_UNKNOWN_CMD = 4'd1,
        ERR_BAD_ARG     = 4'd2,
        ERR_LINK_DOWN   = 4'd3;

    reg r_link_up_d;
    reg r_pending_auto_stat;

    //--------------------------------------------------------------------------
    // Helper: get one char from packed line buffer
    // byte0 -> [7:0], byte1 -> [15:8], ...
    //--------------------------------------------------------------------------
    function [7:0] f_ch;
        input [MAX_LINE_CHARS*8-1:0] line;
        input integer idx;
        begin
            f_ch = line[idx*8 +: 8];
        end
    endfunction

    //--------------------------------------------------------------------------
    // Command match wires
    //--------------------------------------------------------------------------

    // OSD ON
    wire w_cmd_osd_on;
    assign w_cmd_osd_on =
        (i_cmd_len == 8'd6) &&
        (f_ch(i_cmd_data,0) == 8'h4F) && // O
        (f_ch(i_cmd_data,1) == 8'h53) && // S
        (f_ch(i_cmd_data,2) == 8'h44) && // D
        (f_ch(i_cmd_data,3) == 8'h20) && // ' '
        (f_ch(i_cmd_data,4) == 8'h4F) && // O
        (f_ch(i_cmd_data,5) == 8'h4E);   // N

    // OSD OFF
    wire w_cmd_osd_off;
    assign w_cmd_osd_off =
        (i_cmd_len == 8'd7) &&
        (f_ch(i_cmd_data,0) == 8'h4F) && // O
        (f_ch(i_cmd_data,1) == 8'h53) && // S
        (f_ch(i_cmd_data,2) == 8'h44) && // D
        (f_ch(i_cmd_data,3) == 8'h20) && // ' '
        (f_ch(i_cmd_data,4) == 8'h4F) && // O
        (f_ch(i_cmd_data,5) == 8'h46) && // F
        (f_ch(i_cmd_data,6) == 8'h46);   // F

    // OSD TOGGLE
    wire w_cmd_osd_toggle;
    assign w_cmd_osd_toggle =
        (i_cmd_len == 8'd10) &&
        (f_ch(i_cmd_data,0) == 8'h4F) && // O
        (f_ch(i_cmd_data,1) == 8'h53) && // S
        (f_ch(i_cmd_data,2) == 8'h44) && // D
        (f_ch(i_cmd_data,3) == 8'h20) && // ' '
        (f_ch(i_cmd_data,4) == 8'h54) && // T
        (f_ch(i_cmd_data,5) == 8'h4F) && // O
        (f_ch(i_cmd_data,6) == 8'h47) && // G
        (f_ch(i_cmd_data,7) == 8'h47) && // G
        (f_ch(i_cmd_data,8) == 8'h4C) && // L
        (f_ch(i_cmd_data,9) == 8'h45);   // E

    // MENU UP
    wire w_cmd_menu_up;
    assign w_cmd_menu_up =
        (i_cmd_len == 8'd7) &&
        (f_ch(i_cmd_data,0) == 8'h4D) && // M
        (f_ch(i_cmd_data,1) == 8'h45) && // E
        (f_ch(i_cmd_data,2) == 8'h4E) && // N
        (f_ch(i_cmd_data,3) == 8'h55) && // U
        (f_ch(i_cmd_data,4) == 8'h20) && // ' '
        (f_ch(i_cmd_data,5) == 8'h55) && // U
        (f_ch(i_cmd_data,6) == 8'h50);   // P

    // MENU DOWN
    wire w_cmd_menu_down;
    assign w_cmd_menu_down =
        (i_cmd_len == 8'd9) &&
        (f_ch(i_cmd_data,0) == 8'h4D) && // M
        (f_ch(i_cmd_data,1) == 8'h45) && // E
        (f_ch(i_cmd_data,2) == 8'h4E) && // N
        (f_ch(i_cmd_data,3) == 8'h55) && // U
        (f_ch(i_cmd_data,4) == 8'h20) && // ' '
        (f_ch(i_cmd_data,5) == 8'h44) && // D
        (f_ch(i_cmd_data,6) == 8'h4F) && // O
        (f_ch(i_cmd_data,7) == 8'h57) && // W
        (f_ch(i_cmd_data,8) == 8'h4E);   // N

    // STATUS?
    wire w_cmd_status;
    assign w_cmd_status =
        (i_cmd_len == 8'd7) &&
        (f_ch(i_cmd_data,0) == 8'h53) && // S
        (f_ch(i_cmd_data,1) == 8'h54) && // T
        (f_ch(i_cmd_data,2) == 8'h41) && // A
        (f_ch(i_cmd_data,3) == 8'h54) && // T
        (f_ch(i_cmd_data,4) == 8'h55) && // U
        (f_ch(i_cmd_data,5) == 8'h53) && // S
        (f_ch(i_cmd_data,6) == 8'h3F);   // ?

    // RESET
    wire w_cmd_reset;
    assign w_cmd_reset =
        (i_cmd_len == 8'd5) &&
        (f_ch(i_cmd_data,0) == 8'h52) && // R
        (f_ch(i_cmd_data,1) == 8'h45) && // E
        (f_ch(i_cmd_data,2) == 8'h53) && // S
        (f_ch(i_cmd_data,3) == 8'h45) && // E
        (f_ch(i_cmd_data,4) == 8'h54);   // T

    // HELP?
    wire w_cmd_help;
    assign w_cmd_help =
        (i_cmd_len == 8'd5) &&
        (f_ch(i_cmd_data,0) == 8'h48) && // H
        (f_ch(i_cmd_data,1) == 8'h45) && // E
        (f_ch(i_cmd_data,2) == 8'h4C) && // L
        (f_ch(i_cmd_data,3) == 8'h50) && // P
        (f_ch(i_cmd_data,4) == 8'h3F);   // ?

    // MODE SET COLORBAR
    wire w_cmd_mode_colorbar;
    assign w_cmd_mode_colorbar =
        (i_cmd_len == 8'd17) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) && // M
        (f_ch(i_cmd_data,1)  == 8'h4F) && // O
        (f_ch(i_cmd_data,2)  == 8'h44) && // D
        (f_ch(i_cmd_data,3)  == 8'h45) && // E
        (f_ch(i_cmd_data,4)  == 8'h20) && // ' '
        (f_ch(i_cmd_data,5)  == 8'h53) && // S
        (f_ch(i_cmd_data,6)  == 8'h45) && // E
        (f_ch(i_cmd_data,7)  == 8'h54) && // T
        (f_ch(i_cmd_data,8)  == 8'h20) && // ' '
        (f_ch(i_cmd_data,9)  == 8'h43) && // C
        (f_ch(i_cmd_data,10) == 8'h4F) && // O
        (f_ch(i_cmd_data,11) == 8'h4C) && // L
        (f_ch(i_cmd_data,12) == 8'h4F) && // O
        (f_ch(i_cmd_data,13) == 8'h52) && // R
        (f_ch(i_cmd_data,14) == 8'h42) && // B
        (f_ch(i_cmd_data,15) == 8'h41) && // A
        (f_ch(i_cmd_data,16) == 8'h52);   // R

    // MODE SET NETGRID
    wire w_cmd_mode_netgrid;
    assign w_cmd_mode_netgrid =
        (i_cmd_len == 8'd16) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) &&
        (f_ch(i_cmd_data,1)  == 8'h4F) &&
        (f_ch(i_cmd_data,2)  == 8'h44) &&
        (f_ch(i_cmd_data,3)  == 8'h45) &&
        (f_ch(i_cmd_data,4)  == 8'h20) &&
        (f_ch(i_cmd_data,5)  == 8'h53) &&
        (f_ch(i_cmd_data,6)  == 8'h45) &&
        (f_ch(i_cmd_data,7)  == 8'h54) &&
        (f_ch(i_cmd_data,8)  == 8'h20) &&
        (f_ch(i_cmd_data,9)  == 8'h4E) && // N
        (f_ch(i_cmd_data,10) == 8'h45) && // E
        (f_ch(i_cmd_data,11) == 8'h54) && // T
        (f_ch(i_cmd_data,12) == 8'h47) && // G
        (f_ch(i_cmd_data,13) == 8'h52) && // R
        (f_ch(i_cmd_data,14) == 8'h49) && // I
        (f_ch(i_cmd_data,15) == 8'h44);   // D

    // MODE SET GRAY
    wire w_cmd_mode_gray;
    assign w_cmd_mode_gray =
        (i_cmd_len == 8'd13) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) &&
        (f_ch(i_cmd_data,1)  == 8'h4F) &&
        (f_ch(i_cmd_data,2)  == 8'h44) &&
        (f_ch(i_cmd_data,3)  == 8'h45) &&
        (f_ch(i_cmd_data,4)  == 8'h20) &&
        (f_ch(i_cmd_data,5)  == 8'h53) &&
        (f_ch(i_cmd_data,6)  == 8'h45) &&
        (f_ch(i_cmd_data,7)  == 8'h54) &&
        (f_ch(i_cmd_data,8)  == 8'h20) &&
        (f_ch(i_cmd_data,9)  == 8'h47) && // G
        (f_ch(i_cmd_data,10) == 8'h52) && // R
        (f_ch(i_cmd_data,11) == 8'h41) && // A
        (f_ch(i_cmd_data,12) == 8'h59);   // Y

    // MODE SET BWSQUARE
    wire w_cmd_mode_bwsquare;
    assign w_cmd_mode_bwsquare =
        (i_cmd_len == 8'd17) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) &&
        (f_ch(i_cmd_data,1)  == 8'h4F) &&
        (f_ch(i_cmd_data,2)  == 8'h44) &&
        (f_ch(i_cmd_data,3)  == 8'h45) &&
        (f_ch(i_cmd_data,4)  == 8'h20) &&
        (f_ch(i_cmd_data,5)  == 8'h53) &&
        (f_ch(i_cmd_data,6)  == 8'h45) &&
        (f_ch(i_cmd_data,7)  == 8'h54) &&
        (f_ch(i_cmd_data,8)  == 8'h20) &&
        (f_ch(i_cmd_data,9)  == 8'h42) && // B
        (f_ch(i_cmd_data,10) == 8'h57) && // W
        (f_ch(i_cmd_data,11) == 8'h53) && // S
        (f_ch(i_cmd_data,12) == 8'h51) && // Q
        (f_ch(i_cmd_data,13) == 8'h55) && // U
        (f_ch(i_cmd_data,14) == 8'h41) && // A
        (f_ch(i_cmd_data,15) == 8'h52) && // R
        (f_ch(i_cmd_data,16) == 8'h45);   // E

    // MODE SET RED
    wire w_cmd_mode_red;
    assign w_cmd_mode_red =
        (i_cmd_len == 8'd12) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) &&
        (f_ch(i_cmd_data,1)  == 8'h4F) &&
        (f_ch(i_cmd_data,2)  == 8'h44) &&
        (f_ch(i_cmd_data,3)  == 8'h45) &&
        (f_ch(i_cmd_data,4)  == 8'h20) &&
        (f_ch(i_cmd_data,5)  == 8'h53) &&
        (f_ch(i_cmd_data,6)  == 8'h45) &&
        (f_ch(i_cmd_data,7)  == 8'h54) &&
        (f_ch(i_cmd_data,8)  == 8'h20) &&
        (f_ch(i_cmd_data,9)  == 8'h52) && // R
        (f_ch(i_cmd_data,10) == 8'h45) && // E
        (f_ch(i_cmd_data,11) == 8'h44);   // D

    // MODE SET GREEN
    wire w_cmd_mode_green;
    assign w_cmd_mode_green =
        (i_cmd_len == 8'd14) &&
        (f_ch(i_cmd_data,0)  == 8'h4D) &&
        (f_ch(i_cmd_data,1)  == 8'h4F) &&
        (f_ch(i_cmd_data,2)  == 8'h44) &&
        (f_ch(i_cmd_data,3)  == 8'h45) &&
        (f_ch(i_cmd_data,4)  == 8'h20) &&
        (f_ch(i_cmd_data,5)  == 8'h53) &&
        (f_ch(i_cmd_data,6)  == 8'h45) &&
        (f_ch(i_cmd_data,7)  == 8'h54) &&
        (f_ch(i_cmd_data,8)  == 8'h20) &&
        (f_ch(i_cmd_data,9)  == 8'h47) && // G
        (f_ch(i_cmd_data,10) == 8'h52) && // R
        (f_ch(i_cmd_data,11) == 8'h45) && // E
        (f_ch(i_cmd_data,12) == 8'h45) && // E
        (f_ch(i_cmd_data,13) == 8'h4E);   // N

    //--------------------------------------------------------------------------
    // Edge detect
    //--------------------------------------------------------------------------
    wire w_link_down_edge;
    wire w_link_up_edge;

    assign w_link_down_edge =  r_link_up_d & (~i_link_up);
    assign w_link_up_edge   = (~r_link_up_d) &   i_link_up;

    //--------------------------------------------------------------------------
    // Helper task: push one structured response
    //--------------------------------------------------------------------------
    task t_push_resp;
        input [3:0] resp_kind;
        input [3:0] resp_err;
        input       resp_link_up;
        input       resp_osd_on;
        input [2:0] resp_menu;
        input [2:0] resp_mode;
        begin
            o_resp_valid       <= 1'b1;
            o_resp_kind        <= resp_kind;
            o_resp_err_code    <= resp_err;
            o_resp_link_up     <= resp_link_up;
            o_resp_osd_on      <= resp_osd_on;
            o_resp_menu_index  <= resp_menu;
            o_resp_active_mode <= resp_mode;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main FSM / state update
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_osd_on               <= 1'b0;
            o_menu_index           <= 3'd0;
            o_active_mode          <= 3'd0;

            o_resp_valid           <= 1'b0;
            o_resp_kind            <= RESP_NONE;
            o_resp_err_code        <= ERR_NONE;
            o_resp_link_up         <= 1'b0;
            o_resp_osd_on          <= 1'b0;
            o_resp_menu_index      <= 3'd0;
            o_resp_active_mode     <= 3'd0;

            o_unknown_cmd_sticky   <= 1'b0;
            o_bad_arg_sticky       <= 1'b0;
            o_linkdown_cmd_sticky  <= 1'b0;
            o_cmd_while_busy_sticky<= 1'b0;

            r_link_up_d            <= 1'b0;
            r_pending_auto_stat    <= 1'b0;
        end
        else begin
            // 默认保持
            r_link_up_d <= i_link_up;

            // 如果当前有 response 正在等待 formatter 接收，则先等待
            if (o_resp_valid) begin
                if (i_resp_ready) begin
                    o_resp_valid <= 1'b0;
                end

                if (i_cmd_valid)
                    o_cmd_while_busy_sticky <= 1'b1;
            end
            else begin
                // 1) 优先处理 pending auto STAT
                if (r_pending_auto_stat) begin
                    t_push_resp(RESP_STAT, ERR_NONE, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    r_pending_auto_stat <= 1'b0;
                end

                // 2) 再处理链路事件
                else if (w_link_down_edge) begin
                    o_osd_on      <= 1'b0;
                    o_menu_index  <= 3'd0;
                    o_active_mode <= 3'd0;

                    t_push_resp(RESP_WARN_LINK_DOWN, ERR_NONE, 1'b0, 1'b0, 3'd0, 3'd0);
                end
                else if (w_link_up_edge) begin
                    o_osd_on      <= 1'b0;
                    o_menu_index  <= 3'd0;
                    o_active_mode <= 3'd0;

                    t_push_resp(RESP_INFO_LINK_UP_RST, ERR_NONE, 1'b1, 1'b0, 3'd0, 3'd0);
                    r_pending_auto_stat <= 1'b1;
                end

                // 3) 再处理命令
                else if (i_cmd_valid) begin
                    // 链路断开时，只允许 STATUS? / HELP?，其余命令报 ERR LINK_DOWN
                    if (!i_link_up && !w_cmd_status && !w_cmd_help) begin
                        o_linkdown_cmd_sticky <= 1'b1;
                        t_push_resp(RESP_ERR, ERR_LINK_DOWN, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    end

                    else if (w_cmd_osd_on) begin
                        o_osd_on <= 1'b1;
                        t_push_resp(RESP_OK_OSD, ERR_NONE, i_link_up, 1'b1, o_menu_index, o_active_mode);
                    end

                    else if (w_cmd_osd_off) begin
                        o_osd_on <= 1'b0;
                        t_push_resp(RESP_OK_OSD, ERR_NONE, i_link_up, 1'b0, o_menu_index, o_active_mode);
                    end

                    else if (w_cmd_osd_toggle) begin
                        o_osd_on <= ~o_osd_on;
                        t_push_resp(RESP_OK_OSD, ERR_NONE, i_link_up, ~o_osd_on, o_menu_index, o_active_mode);
                    end

                    else if (w_cmd_menu_up) begin
                        if (o_menu_index == 3'd0) begin
                            o_menu_index  <= MODE_COUNT-1;
                            o_active_mode <= MODE_COUNT-1;
                            t_push_resp(RESP_OK_MENU, ERR_NONE, i_link_up, o_osd_on, MODE_COUNT-1, MODE_COUNT-1);
                        end
                        else begin
                            o_menu_index  <= o_menu_index - 3'd1;
                            o_active_mode <= o_menu_index - 3'd1;
                            t_push_resp(RESP_OK_MENU, ERR_NONE, i_link_up, o_osd_on, o_menu_index - 3'd1, o_menu_index - 3'd1);
                        end
                    end

                    else if (w_cmd_menu_down) begin
                        if (o_menu_index == (MODE_COUNT-1)) begin
                            o_menu_index  <= 3'd0;
                            o_active_mode <= 3'd0;
                            t_push_resp(RESP_OK_MENU, ERR_NONE, i_link_up, o_osd_on, 3'd0, 3'd0);
                        end
                        else begin
                            o_menu_index  <= o_menu_index + 3'd1;
                            o_active_mode <= o_menu_index + 3'd1;
                            t_push_resp(RESP_OK_MENU, ERR_NONE, i_link_up, o_osd_on, o_menu_index + 3'd1, o_menu_index + 3'd1);
                        end
                    end

                    else if (w_cmd_mode_colorbar) begin
                        o_menu_index  <= 3'd0;
                        o_active_mode <= 3'd0;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd0, 3'd0);
                    end

                    else if (w_cmd_mode_netgrid) begin
                        o_menu_index  <= 3'd1;
                        o_active_mode <= 3'd1;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd1, 3'd1);
                    end

                    else if (w_cmd_mode_gray) begin
                        o_menu_index  <= 3'd2;
                        o_active_mode <= 3'd2;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd2, 3'd2);
                    end

                    else if (w_cmd_mode_bwsquare) begin
                        o_menu_index  <= 3'd3;
                        o_active_mode <= 3'd3;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd3, 3'd3);
                    end

                    else if (w_cmd_mode_red) begin
                        o_menu_index  <= 3'd4;
                        o_active_mode <= 3'd4;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd4, 3'd4);
                    end

                    else if (w_cmd_mode_green) begin
                        o_menu_index  <= 3'd5;
                        o_active_mode <= 3'd5;
                        t_push_resp(RESP_OK_MODE, ERR_NONE, i_link_up, o_osd_on, 3'd5, 3'd5);
                    end

                    else if (w_cmd_status) begin
                        t_push_resp(RESP_STAT, ERR_NONE, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    end

                    else if (w_cmd_reset) begin
                        o_osd_on      <= 1'b0;
                        o_menu_index  <= 3'd0;
                        o_active_mode <= 3'd0;

                        t_push_resp(RESP_OK_RESET, ERR_NONE, i_link_up, 1'b0, 3'd0, 3'd0);
                        r_pending_auto_stat <= 1'b1;
                    end

                    else if (w_cmd_help) begin
                        t_push_resp(RESP_HELP, ERR_NONE, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    end

                    else begin
                        o_unknown_cmd_sticky <= 1'b1;
                        t_push_resp(RESP_ERR, ERR_UNKNOWN_CMD, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    end
                end
            end
        end
    end

endmodule