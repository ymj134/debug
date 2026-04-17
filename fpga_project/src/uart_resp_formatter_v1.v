`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_resp_formatter_v1
* Description  :
*   将 demo_ctrl_fsm_v1 的结构化响应格式化成 ASCII 文本，并逐字节输出
*
* Fixed version:
*   修复了“每隔一个字符丢一个”的握手问题：
*   - o_byte_valid 在发送期间保持为 1
*   - o_byte_data 始终指向当前 r_tx_idx 对应字符
*   - 只有在 i_byte_ready=1 时，才前进到下一个字符
*********************************************************************************/

module uart_resp_formatter_v1
#(
    parameter integer MAX_RESP_CHARS = 96
)
(
    input                           i_clk,
    input                           i_rst_n,

    // 来自 demo_ctrl_fsm_v1 的结构化响应
    input                           i_resp_valid,
    output reg                      o_resp_ready,
    input       [3:0]               i_resp_kind,
    input       [3:0]               i_resp_err_code,
    input                           i_resp_link_up,
    input                           i_resp_osd_on,
    input       [2:0]               i_resp_menu_index,
    input       [2:0]               i_resp_active_mode,

    // 输出到 uart_tx_byte_v1
    output      [7:0]               o_byte_data,
    output                          o_byte_valid,
    input                           i_byte_ready,

    // debug
    output reg                      o_busy,
    output reg  [7:0]               o_dbg_len,
    output reg                      o_overflow_sticky
);

    //--------------------------------------------------------------------------
    // Response kind enum（与 demo_ctrl_fsm_v1 保持一致）
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
    // Response error code enum（与 demo_ctrl_fsm_v1 保持一致）
    //--------------------------------------------------------------------------
    localparam [3:0]
        ERR_NONE        = 4'd0,
        ERR_UNKNOWN_CMD = 4'd1,
        ERR_BAD_ARG     = 4'd2,
        ERR_LINK_DOWN   = 4'd3;

    localparam integer BUF_W = MAX_RESP_CHARS * 8;

    reg [BUF_W-1:0] r_buf;
    reg [7:0]       r_len;
    reg [7:0]       r_tx_idx;
    reg             r_tx_active;

    reg [BUF_W-1:0] build_buf;
    reg [7:0]       build_len;
    reg             build_overflow;

    assign o_byte_valid = r_tx_active;
    assign o_byte_data  = r_buf[r_tx_idx*8 +: 8];

    //--------------------------------------------------------------------------
    // Helper tasks for build buffer
    //--------------------------------------------------------------------------
    task t_build_clear;
        begin
            build_buf      = {BUF_W{1'b0}};
            build_len      = 8'd0;
            build_overflow = 1'b0;
        end
    endtask

    task t_put_char;
        input [7:0] c;
        begin
            if (build_len < MAX_RESP_CHARS[7:0]) begin
                build_buf[build_len*8 +: 8] = c;
                build_len = build_len + 8'd1;
            end
            else begin
                build_overflow = 1'b1;
            end
        end
    endtask

    task t_put_space;
        begin
            t_put_char(8'h20);
        end
    endtask

    task t_put_crlf;
        begin
            t_put_char(8'h0D);
            t_put_char(8'h0A);
        end
    endtask

    task t_put_digit;
        input [2:0] d;
        begin
            t_put_char(8'h30 + d);
        end
    endtask

    task t_put_onoff;
        input v;
        begin
            if (v) begin
                t_put_char("O");
                t_put_char("N");
            end
            else begin
                t_put_char("O");
                t_put_char("F");
                t_put_char("F");
            end
        end
    endtask

    task t_put_link;
        input v;
        begin
            if (v) begin
                t_put_char("U");
                t_put_char("P");
            end
            else begin
                t_put_char("D");
                t_put_char("O");
                t_put_char("W");
                t_put_char("N");
            end
        end
    endtask

    task t_put_mode_name;
        input [2:0] mode;
        begin
            case (mode)
                3'd0: begin
                    t_put_char("C"); t_put_char("O"); t_put_char("L"); t_put_char("O");
                    t_put_char("R"); t_put_char("B"); t_put_char("A"); t_put_char("R");
                end
                3'd1: begin
                    t_put_char("N"); t_put_char("E"); t_put_char("T"); t_put_char("G");
                    t_put_char("R"); t_put_char("I"); t_put_char("D");
                end
                3'd2: begin
                    t_put_char("G"); t_put_char("R"); t_put_char("A"); t_put_char("Y");
                end
                3'd3: begin
                    t_put_char("B"); t_put_char("W"); t_put_char("S"); t_put_char("Q");
                    t_put_char("U"); t_put_char("A"); t_put_char("R"); t_put_char("E");
                end
                3'd4: begin
                    t_put_char("R"); t_put_char("E"); t_put_char("D");
                end
                3'd5: begin
                    t_put_char("G"); t_put_char("R"); t_put_char("E"); t_put_char("E"); t_put_char("N");
                end
                default: begin
                    t_put_char("U"); t_put_char("N"); t_put_char("K"); t_put_char("N");
                    t_put_char("O"); t_put_char("W"); t_put_char("N");
                end
            endcase
        end
    endtask

    //--------------------------------------------------------------------------
    // Main formatter
    //--------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_buf             <= {BUF_W{1'b0}};
            r_len             <= 8'd0;
            r_tx_idx          <= 8'd0;
            r_tx_active       <= 1'b0;

            o_resp_ready      <= 1'b0;
            o_busy            <= 1'b0;
            o_dbg_len         <= 8'd0;
            o_overflow_sticky <= 1'b0;
        end
        else begin
            o_resp_ready <= 1'b0;
            o_busy       <= r_tx_active;

            // --------------------------------------------------------------
            // 1) 正在发送时：只有 ready 到来，才前进到下一个字符
            // --------------------------------------------------------------
            if (r_tx_active) begin
                if (i_byte_ready) begin
                    if (r_tx_idx == (r_len - 8'd1)) begin
                        r_tx_idx    <= 8'd0;
                        r_tx_active <= 1'b0;
                    end
                    else begin
                        r_tx_idx <= r_tx_idx + 8'd1;
                    end
                end
            end

            // --------------------------------------------------------------
            // 2) 空闲时：接收一条新的结构化响应并格式化
            // --------------------------------------------------------------
            else if (i_resp_valid) begin
                t_build_clear;

                case (i_resp_kind)
                    RESP_OK_OSD: begin
                        t_put_char("O"); t_put_char("K"); t_put_space;
                        t_put_char("O"); t_put_char("S"); t_put_char("D"); t_put_space;
                        t_put_onoff(i_resp_osd_on);
                        t_put_crlf;
                    end

                    RESP_OK_MENU: begin
                        t_put_char("O"); t_put_char("K"); t_put_space;
                        t_put_char("M"); t_put_char("E"); t_put_char("N"); t_put_char("U"); t_put_space;
                        t_put_digit(i_resp_menu_index); t_put_space;
                        t_put_mode_name(i_resp_menu_index);
                        t_put_crlf;
                    end

                    RESP_OK_MODE: begin
                        t_put_char("O"); t_put_char("K"); t_put_space;
                        t_put_char("M"); t_put_char("O"); t_put_char("D"); t_put_char("E"); t_put_space;
                        t_put_digit(i_resp_active_mode); t_put_space;
                        t_put_mode_name(i_resp_active_mode);
                        t_put_crlf;
                    end

                    RESP_OK_RESET: begin
                        t_put_char("O"); t_put_char("K"); t_put_space;
                        t_put_char("R"); t_put_char("E"); t_put_char("S"); t_put_char("E"); t_put_char("T");
                        t_put_crlf;
                    end

                    RESP_STAT: begin
                        t_put_char("S"); t_put_char("T"); t_put_char("A"); t_put_char("T"); t_put_space;
                        t_put_char("L"); t_put_char("I"); t_put_char("N"); t_put_char("K"); t_put_space;
                        t_put_link(i_resp_link_up); t_put_space;
                        t_put_char("O"); t_put_char("S"); t_put_char("D"); t_put_space;
                        t_put_onoff(i_resp_osd_on); t_put_space;
                        t_put_char("M"); t_put_char("E"); t_put_char("N"); t_put_char("U"); t_put_space;
                        t_put_digit(i_resp_menu_index); t_put_space;
                        t_put_char("M"); t_put_char("O"); t_put_char("D"); t_put_char("E"); t_put_space;
                        t_put_mode_name(i_resp_active_mode);
                        t_put_crlf;
                    end

                    RESP_WARN_LINK_DOWN: begin
                        t_put_char("W"); t_put_char("A"); t_put_char("R"); t_put_char("N"); t_put_space;
                        t_put_char("L"); t_put_char("I"); t_put_char("N"); t_put_char("K"); t_put_space;
                        t_put_char("D"); t_put_char("O"); t_put_char("W"); t_put_char("N");
                        t_put_crlf;
                    end

                    RESP_INFO_LINK_UP_RST: begin
                        t_put_char("I"); t_put_char("N"); t_put_char("F"); t_put_char("O"); t_put_space;
                        t_put_char("L"); t_put_char("I"); t_put_char("N"); t_put_char("K"); t_put_space;
                        t_put_char("U"); t_put_char("P"); t_put_space;
                        t_put_char("R"); t_put_char("E"); t_put_char("S"); t_put_char("E"); t_put_char("T");
                        t_put_crlf;
                    end

                    RESP_HELP: begin
                        t_put_char("H"); t_put_char("E"); t_put_char("L"); t_put_char("P"); t_put_space;
                        t_put_char("O"); t_put_char("S"); t_put_char("D"); t_put_space;
                        t_put_char("O"); t_put_char("N"); t_put_char("|");
                        t_put_char("O"); t_put_char("F"); t_put_char("F"); t_put_char("|");
                        t_put_char("T"); t_put_char("O"); t_put_char("G"); t_put_char("G"); t_put_char("L"); t_put_char("E");
                        t_put_char(","); t_put_space;

                        t_put_char("M"); t_put_char("E"); t_put_char("N"); t_put_char("U"); t_put_space;
                        t_put_char("U"); t_put_char("P"); t_put_char("|");
                        t_put_char("D"); t_put_char("O"); t_put_char("W"); t_put_char("N");
                        t_put_char(","); t_put_space;

                        t_put_char("M"); t_put_char("O"); t_put_char("D"); t_put_char("E"); t_put_space;
                        t_put_char("S"); t_put_char("E"); t_put_char("T"); t_put_space;
                        t_put_char("<"); t_put_char("N"); t_put_char("A"); t_put_char("M"); t_put_char("E"); t_put_char(">");
                        t_put_char(","); t_put_space;

                        t_put_char("S"); t_put_char("T"); t_put_char("A"); t_put_char("T"); t_put_char("U"); t_put_char("S"); t_put_char("?");
                        t_put_char(","); t_put_space;

                        t_put_char("R"); t_put_char("E"); t_put_char("S"); t_put_char("E"); t_put_char("T");
                        t_put_crlf;
                    end

                    RESP_ERR: begin
                        t_put_char("E"); t_put_char("R"); t_put_char("R"); t_put_space;
                        case (i_resp_err_code)
                            ERR_UNKNOWN_CMD: begin
                                t_put_char("U"); t_put_char("N"); t_put_char("K"); t_put_char("N");
                                t_put_char("O"); t_put_char("W"); t_put_char("N"); t_put_space;
                                t_put_char("C"); t_put_char("M"); t_put_char("D");
                            end
                            ERR_BAD_ARG: begin
                                t_put_char("B"); t_put_char("A"); t_put_char("D"); t_put_space;
                                t_put_char("A"); t_put_char("R"); t_put_char("G");
                            end
                            ERR_LINK_DOWN: begin
                                t_put_char("L"); t_put_char("I"); t_put_char("N"); t_put_char("K"); t_put_space;
                                t_put_char("D"); t_put_char("O"); t_put_char("W"); t_put_char("N");
                            end
                            default: begin
                                t_put_char("U"); t_put_char("N"); t_put_char("K"); t_put_char("N");
                                t_put_char("O"); t_put_char("W"); t_put_char("N");
                            end
                        endcase
                        t_put_crlf;
                    end

                    default: begin
                        t_put_char("E"); t_put_char("R"); t_put_char("R");
                        t_put_crlf;
                    end
                endcase

                o_resp_ready <= 1'b1;

                r_buf       <= build_buf;
                r_len       <= build_len;
                r_tx_idx    <= 8'd0;
                r_tx_active <= (build_len != 8'd0);

                o_dbg_len   <= build_len;

                if (build_overflow)
                    o_overflow_sticky <= 1'b1;
            end
        end
    end

endmodule