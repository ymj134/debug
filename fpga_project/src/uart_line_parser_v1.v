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
* Fixed version:
*   - 不再对 packed vector 做变量位选写入
*   - 改用 byte memory 收字符，再在换行时统一拼包
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
    reg [7:0] r_mem [0:MAX_LINE_CHARS-1];

    reg [LINE_W-1:0] v_line;

    integer i;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_len                   <= 8'd0;
            o_line_data             <= {LINE_W{1'b0}};
            o_line_len              <= 8'd0;
            o_line_valid            <= 1'b0;
            o_overflow_sticky       <= 1'b0;
            o_empty_line_seen_pulse <= 1'b0;

            for (i = 0; i < MAX_LINE_CHARS; i = i + 1)
                r_mem[i] <= 8'd0;
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
                            v_line = {LINE_W{1'b0}};
                            for (i = 0; i < MAX_LINE_CHARS; i = i + 1) begin
                                if (i < r_len)
                                    v_line[i*8 +: 8] = r_mem[i];
                            end

                            o_line_data  <= v_line;
                            o_line_len   <= r_len;
                            o_line_valid <= 1'b1;
                        end
                        else begin
                            o_empty_line_seen_pulse <= 1'b1;
                        end

                        r_len <= 8'd0;
                    end

                    default: begin
                        if (r_len < MAX_LINE_CHARS[7:0]) begin
                            r_mem[r_len] <= i_byte_data;
                            r_len        <= r_len + 8'd1;
                        end
                        else begin
                            o_overflow_sticky <= 1'b1;
                        end
                    end
                endcase
            end
        end
    end

endmodule