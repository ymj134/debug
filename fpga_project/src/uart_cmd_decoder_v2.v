`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_cmd_decoder_v2
* Description  :
*   简单 UART 命令解码器（sys_clk 域）
*
* Supported commands:
*   '1' (8'h31) : OSD ON
*   '0' (8'h30) : OSD OFF
*   'T' (8'h54) : OSD TOGGLE
*
*   'A' (8'h41) : pattern_mode = 0  正常视频
*   'B' (8'h42) : pattern_mode = 1  纯红
*   'C' (8'h43) : pattern_mode = 2  纯绿
*   'D' (8'h44) : pattern_mode = 3  纯蓝
*   'E' (8'h45) : pattern_mode = 4  棋盘格
*   'F' (8'h46) : pattern_mode = 5  灰阶条
*
*   'S' (8'h53) : 触发一次状态查询请求脉冲
*
* Notes:
*   1) 输入字节一般来自 uart_word_unpacker_v1 的输出
*   2) 本模块只解析命令，不阻断原始 UART 字节继续送往 tx_o
*********************************************************************************/

module uart_cmd_decoder_v2
(
    input               i_clk,
    input               i_rst_n,

    input      [7:0]    i_byte_data,
    input               i_byte_valid,

    output reg          o_osd_enable,
    output reg  [2:0]   o_pattern_mode,
    output reg          o_status_req_pulse,

    output reg  [7:0]   o_last_cmd,
    output reg          o_cmd_seen_pulse,
    output reg          o_unknown_cmd_sticky
);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_osd_enable         <= 1'b0;
            o_pattern_mode       <= 3'd0;
            o_status_req_pulse   <= 1'b0;
            o_last_cmd           <= 8'd0;
            o_cmd_seen_pulse     <= 1'b0;
            o_unknown_cmd_sticky <= 1'b0;
        end
        else begin
            o_cmd_seen_pulse   <= 1'b0;
            o_status_req_pulse <= 1'b0;

            if (i_byte_valid) begin
                o_last_cmd       <= i_byte_data;
                o_cmd_seen_pulse <= 1'b1;

                case (i_byte_data)
                    8'h31: begin // '1'
                        o_osd_enable <= 1'b1;
                    end

                    8'h30: begin // '0'
                        o_osd_enable <= 1'b0;
                    end

                    8'h54: begin // 'T'
                        o_osd_enable <= ~o_osd_enable;
                    end

                    8'h41: begin // 'A'
                        o_pattern_mode <= 3'd0;
                    end

                    8'h42: begin // 'B'
                        o_pattern_mode <= 3'd1;
                    end

                    8'h43: begin // 'C'
                        o_pattern_mode <= 3'd2;
                    end

                    8'h44: begin // 'D'
                        o_pattern_mode <= 3'd3;
                    end

                    8'h45: begin // 'E'
                        o_pattern_mode <= 3'd4;
                    end

                    8'h46: begin // 'F'
                        o_pattern_mode <= 3'd5;
                    end

                    8'h53: begin // 'S'
                        o_status_req_pulse <= 1'b1;
                    end

                    default: begin
                        o_unknown_cmd_sticky <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule