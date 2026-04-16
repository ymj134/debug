`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_cmd_decoder_v1
* Description  :
*   简单 UART 命令解码器（sys_clk 域）
*
* Supported commands:
*   '1' (8'h31) : OSD ON
*   '0' (8'h30) : OSD OFF
*   'T' (8'h54) : OSD TOGGLE
*
* Notes:
*   1) 输入字节一般来自 uart_word_unpacker_v1 的输出
*   2) 本模块只解析命令，不阻断原始 UART 字节继续送往 tx_o
*********************************************************************************/

module uart_cmd_decoder_v1
(
    input               i_clk,
    input               i_rst_n,

    input      [7:0]    i_byte_data,
    input               i_byte_valid,

    output reg          o_osd_enable,

    output reg  [7:0]   o_last_cmd,
    output reg          o_cmd_seen_pulse,
    output reg          o_unknown_cmd_sticky
);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_osd_enable         <= 1'b0;
            o_last_cmd           <= 8'd0;
            o_cmd_seen_pulse     <= 1'b0;
            o_unknown_cmd_sticky <= 1'b0;
        end
        else begin
            o_cmd_seen_pulse <= 1'b0;

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

                    default: begin
                        o_unknown_cmd_sticky <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule