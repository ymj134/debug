`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_line_parser_v1
* Description  :
*   将 UART 字节流拼成一整行 ASCII 命令
*
* Protocol rules:
*   1) 以 '\n' (8'h0A) 作为命令结束
*   2) '\r' (8'h0D) 被忽略，因此兼容 "\r\n"
*   3) 行内容不包含结尾的 '\r' / '\n'
*   4) 输出一拍 o_line_valid，表示当前 o_line_data/o_line_len 有效
*
* Notes:
*   1) 本模块不做命令解析，只做“按行收集”
*   2) 若一行超长，会截断并拉高 overflow sticky
*   3) 空行（长度为 0）默认忽略，不输出 o_line_valid
*********************************************************************************/

module uart_line_parser_v1
#(
    parameter integer MAX_LINE_CHARS = 31
)
(
    input                               i_clk,
    input                               i_rst_n,

    input       [7:0]                   i_byte_data,
    input                               i_byte_valid,

    output reg  [MAX_LINE_CHARS*8-1:0]  o_line_data,
    output reg  [7:0]                   o_line_len,
    output reg                          o_line_valid,

    output reg                          o_overflow_sticky,
    output reg                          o_empty_line_seen_pulse
);

    localparam integer LINE_W = MAX_LINE_CHARS * 8;

    reg [7:0] r_len;
    reg [LINE_W-1:0] r_buf;

    integer k;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_len                  <= 8'd0;
            r_buf                  <= {LINE_W{1'b0}};

            o_line_data            <= {LINE_W{1'b0}};
            o_line_len             <= 8'd0;
            o_line_valid           <= 1'b0;

            o_overflow_sticky      <= 1'b0;
            o_empty_line_seen_pulse<= 1'b0;
        end
        else begin
            o_line_valid            <= 1'b0;
            o_empty_line_seen_pulse <= 1'b0;

            if (i_byte_valid) begin
                case (i_byte_data)
                    8'h0D: begin
                        // '\r' ignore
                    end

                    8'h0A: begin
                        // '\n' line end
                        if (r_len != 8'd0) begin
                            o_line_data  <= r_buf;
                            o_line_len   <= r_len;
                            o_line_valid <= 1'b1;
                        end
                        else begin
                            o_empty_line_seen_pulse <= 1'b1;
                        end

                        // clear current buffer
                        r_len <= 8'd0;
                        r_buf <= {LINE_W{1'b0}};
                    end

                    default: begin
                        if (r_len < MAX_LINE_CHARS[7:0]) begin
                            // store byte into low-to-high packed buffer:
                            // byte0 -> [7:0], byte1 -> [15:8], ...
                            r_buf[r_len*8 +: 8] <= i_byte_data;
                            r_len <= r_len + 8'd1;
                        end
                        else begin
                            // line too long: keep truncating, wait for '\n'
                            o_overflow_sticky <= 1'b1;
                        end
                    end
                endcase
            end
        end
    end

endmodule
