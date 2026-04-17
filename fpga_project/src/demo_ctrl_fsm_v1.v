`timescale 1ns / 1ps

module demo_ctrl_fsm_v1
#(
    parameter integer MAX_LINE_CHARS = 31,
    parameter integer MODE_COUNT     = 6
)
(
    input                               i_clk,
    input                               i_rst_n,

    input                               i_link_up,

    input       [MAX_LINE_CHARS*8-1:0]  i_cmd_data,
    input       [7:0]                   i_cmd_len,
    input                               i_cmd_valid,

    output reg                          o_osd_on,
    output reg  [2:0]                   o_menu_index,
    output reg  [2:0]                   o_active_mode,

    output reg                          o_resp_valid,
    input                               i_resp_ready,
    output reg  [3:0]                   o_resp_kind,
    output reg  [3:0]                   o_resp_err_code,
    output reg                          o_resp_link_up,
    output reg                          o_resp_osd_on,
    output reg  [2:0]                   o_resp_menu_index,
    output reg  [2:0]                   o_resp_active_mode,

    output reg                          o_unknown_cmd_sticky,
    output reg                          o_bad_arg_sticky,
    output reg                          o_linkdown_cmd_sticky,
    output reg                          o_cmd_while_busy_sticky
);

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

    localparam [3:0]
        ERR_NONE        = 4'd0,
        ERR_UNKNOWN_CMD = 4'd1,
        ERR_BAD_ARG     = 4'd2,
        ERR_LINK_DOWN   = 4'd3;

    reg r_link_up_d;
    reg r_pending_auto_stat;

    //--------------------------------------------------------------------------
    // byte unpack: byte0 -> [7:0], byte1 -> [15:8], ...
    //--------------------------------------------------------------------------
    wire [7:0] c0  = i_cmd_data[7:0];
    wire [7:0] c1  = i_cmd_data[15:8];
    wire [7:0] c2  = i_cmd_data[23:16];
    wire [7:0] c3  = i_cmd_data[31:24];
    wire [7:0] c4  = i_cmd_data[39:32];
    wire [7:0] c5  = i_cmd_data[47:40];
    wire [7:0] c6  = i_cmd_data[55:48];
    wire [7:0] c7  = i_cmd_data[63:56];
    wire [7:0] c8  = i_cmd_data[71:64];
    wire [7:0] c9  = i_cmd_data[79:72];
    wire [7:0] c10 = i_cmd_data[87:80];
    wire [7:0] c11 = i_cmd_data[95:88];
    wire [7:0] c12 = i_cmd_data[103:96];
    wire [7:0] c13 = i_cmd_data[111:104];
    wire [7:0] c14 = i_cmd_data[119:112];
    wire [7:0] c15 = i_cmd_data[127:120];
    wire [7:0] c16 = i_cmd_data[135:128];

    //--------------------------------------------------------------------------
    // command match
    //--------------------------------------------------------------------------
    wire w_cmd_osd_on =
        (i_cmd_len == 8'd6) &&
        (c0=="O") && (c1=="S") && (c2=="D") && (c3==" ") && (c4=="O") && (c5=="N");

    wire w_cmd_osd_off =
        (i_cmd_len == 8'd7) &&
        (c0=="O") && (c1=="S") && (c2=="D") && (c3==" ") &&
        (c4=="O") && (c5=="F") && (c6=="F");

    wire w_cmd_osd_toggle =
        (i_cmd_len == 8'd10) &&
        (c0=="O") && (c1=="S") && (c2=="D") && (c3==" ") &&
        (c4=="T") && (c5=="O") && (c6=="G") && (c7=="G") && (c8=="L") && (c9=="E");

    wire w_cmd_menu_up =
        (i_cmd_len == 8'd7) &&
        (c0=="M") && (c1=="E") && (c2=="N") && (c3=="U") &&
        (c4==" ") && (c5=="U") && (c6=="P");

    wire w_cmd_menu_down =
        (i_cmd_len == 8'd9) &&
        (c0=="M") && (c1=="E") && (c2=="N") && (c3=="U") &&
        (c4==" ") && (c5=="D") && (c6=="O") && (c7=="W") && (c8=="N");

    wire w_cmd_status =
        (i_cmd_len == 8'd7) &&
        (c0=="S") && (c1=="T") && (c2=="A") && (c3=="T") &&
        (c4=="U") && (c5=="S") && (c6=="?");

    wire w_cmd_reset =
        (i_cmd_len == 8'd5) &&
        (c0=="R") && (c1=="E") && (c2=="S") && (c3=="E") && (c4=="T");

    wire w_cmd_help =
        (i_cmd_len == 8'd5) &&
        (c0=="H") && (c1=="E") && (c2=="L") && (c3=="P") && (c4=="?");

    wire w_cmd_mode_colorbar =
        (i_cmd_len == 8'd17) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="C") && (c10=="O") && (c11=="L") && (c12=="O") &&
        (c13=="R") && (c14=="B") && (c15=="A") && (c16=="R");

    wire w_cmd_mode_netgrid =
        (i_cmd_len == 8'd16) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="N") && (c10=="E") && (c11=="T") && (c12=="G") &&
        (c13=="R") && (c14=="I") && (c15=="D");

    wire w_cmd_mode_gray =
        (i_cmd_len == 8'd13) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="G") && (c10=="R") && (c11=="A") && (c12=="Y");

    wire w_cmd_mode_bwsquare =
        (i_cmd_len == 8'd17) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="B") && (c10=="W") && (c11=="S") && (c12=="Q") &&
        (c13=="U") && (c14=="A") && (c15=="R") && (c16=="E");

    wire w_cmd_mode_red =
        (i_cmd_len == 8'd12) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="R") && (c10=="E") && (c11=="D");

    wire w_cmd_mode_green =
        (i_cmd_len == 8'd14) &&
        (c0=="M") && (c1=="O") && (c2=="D") && (c3=="E") && (c4==" ") &&
        (c5=="S") && (c6=="E") && (c7=="T") && (c8==" ") &&
        (c9=="G") && (c10=="R") && (c11=="E") && (c12=="E") && (c13=="N");

    wire w_link_down_edge =  r_link_up_d & (~i_link_up);
    wire w_link_up_edge   = (~r_link_up_d) &   i_link_up;

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

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_osd_on                <= 1'b0;
            o_menu_index            <= 3'd0;
            o_active_mode           <= 3'd0;

            o_resp_valid            <= 1'b0;
            o_resp_kind             <= RESP_NONE;
            o_resp_err_code         <= ERR_NONE;
            o_resp_link_up          <= 1'b0;
            o_resp_osd_on           <= 1'b0;
            o_resp_menu_index       <= 3'd0;
            o_resp_active_mode      <= 3'd0;

            o_unknown_cmd_sticky    <= 1'b0;
            o_bad_arg_sticky        <= 1'b0;
            o_linkdown_cmd_sticky   <= 1'b0;
            o_cmd_while_busy_sticky <= 1'b0;

            r_link_up_d             <= 1'b0;
            r_pending_auto_stat     <= 1'b0;
        end
        else begin
            r_link_up_d <= i_link_up;

            if (o_resp_valid) begin
                if (i_resp_ready)
                    o_resp_valid <= 1'b0;

                if (i_cmd_valid)
                    o_cmd_while_busy_sticky <= 1'b1;
            end
            else begin
                if (r_pending_auto_stat) begin
                    t_push_resp(RESP_STAT, ERR_NONE, i_link_up, o_osd_on, o_menu_index, o_active_mode);
                    r_pending_auto_stat <= 1'b0;
                end
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
                else if (i_cmd_valid) begin
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