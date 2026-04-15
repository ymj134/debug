`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_word_unpacker_v1
* Description  :
*   将 RX_CTRL_FIFO 中的 32-bit UART 控制字还原成 UART 字节
*
* Word format:
*   [31:27] = 5'b10000   // UART_DATA tag
*   [26:24] = channel_id
*   [23:16] = seq
*   [15:8]  = uart_data
*   [7:0]   = crc8(type_byte, seq, uart_data)
*
* Notes:
*   1) 假设输入 FIFO 为 FWFT / Show-Ahead
*   2) 当 i_byte_ready=1 且 FIFO 非空时，消费一个控制字
*   3) tag/channel/crc 正确时，输出 o_byte_valid=1 一拍
*   4) seq 不连续时，默认仍放行当前字节，同时拉高 seq_err_sticky，
*      并把 expected_seq 重同步到当前 seq+1
*********************************************************************************/

module uart_word_unpacker_v1
#(
    parameter [2:0] CHANNEL_ID = 3'b000
)
(
    input               i_clk,
    input               i_rst_n,

    // 来自 RX_CTRL_FIFO（FWFT / Show-Ahead）
    input      [31:0]   i_fifo_dout,
    input               i_fifo_empty,
    output reg          o_fifo_rd_en,

    // 下游 UART TX / byte consumer 是否准备好接收一个字节
    input               i_byte_ready,

    output reg  [7:0]   o_byte_data,
    output reg          o_byte_valid,

    output reg  [7:0]   o_dbg_last_seq,
    output reg  [7:0]   o_dbg_expected_seq,

    output reg          o_type_err_sticky,
    output reg          o_channel_err_sticky,
    output reg          o_crc_err_sticky,
    output reg          o_seq_err_sticky
);

    localparam [4:0] UART_DATA_TAG = 5'b10000;

    reg        r_expected_seq_valid;
    reg [7:0]  r_expected_seq;

    wire [4:0] w_tag;
    wire [2:0] w_channel;
    wire [7:0] w_seq;
    wire [7:0] w_data;
    wire [7:0] w_crc_rx;

    wire [7:0] w_type_byte;
    wire [7:0] w_crc_calc;

    wire       w_type_ok;
    wire       w_channel_ok;
    wire       w_crc_ok;
    wire       w_seq_ok;

    assign w_tag      = i_fifo_dout[31:27];
    assign w_channel  = i_fifo_dout[26:24];
    assign w_seq      = i_fifo_dout[23:16];
    assign w_data     = i_fifo_dout[15:8];
    assign w_crc_rx   = i_fifo_dout[7:0];

    assign w_type_byte  = {UART_DATA_TAG, w_channel};

    //--------------------------------------------------------------------------
    // CRC8 helper
    // poly = x^8 + x^2 + x + 1 = 0x07
    //--------------------------------------------------------------------------
    function [7:0] f_crc8_byte;
        input [7:0] crc_in;
        input [7:0] data_in;
        integer i;
        reg [7:0] crc;
        begin
            crc = crc_in ^ data_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[7])
                    crc = {crc[6:0], 1'b0} ^ 8'h07;
                else
                    crc = {crc[6:0], 1'b0};
            end
            f_crc8_byte = crc;
        end
    endfunction

    function [7:0] f_crc8_word_fields;
        input [7:0] type_byte;
        input [7:0] seq_byte;
        input [7:0] data_byte;
        reg   [7:0] crc;
        begin
            crc = 8'h00;
            crc = f_crc8_byte(crc, type_byte);
            crc = f_crc8_byte(crc, seq_byte);
            crc = f_crc8_byte(crc, data_byte);
            f_crc8_word_fields = crc;
        end
    endfunction

    assign w_crc_calc   = f_crc8_word_fields(w_type_byte, w_seq, w_data);

    assign w_type_ok    = (w_tag == UART_DATA_TAG);
    assign w_channel_ok = (w_channel == CHANNEL_ID);
    assign w_crc_ok     = (w_crc_calc == w_crc_rx);
    assign w_seq_ok     = (!r_expected_seq_valid) || (w_seq == r_expected_seq);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_fifo_rd_en            <= 1'b0;
            o_byte_data             <= 8'd0;
            o_byte_valid            <= 1'b0;

            o_dbg_last_seq          <= 8'd0;
            o_dbg_expected_seq      <= 8'd0;

            o_type_err_sticky       <= 1'b0;
            o_channel_err_sticky    <= 1'b0;
            o_crc_err_sticky        <= 1'b0;
            o_seq_err_sticky        <= 1'b0;

            r_expected_seq_valid    <= 1'b0;
            r_expected_seq          <= 8'd0;
        end
        else begin
            o_fifo_rd_en <= 1'b0;
            o_byte_valid <= 1'b0;

            if (i_byte_ready && !i_fifo_empty) begin
                // 消费当前这个控制字
                o_fifo_rd_en   <= 1'b1;
                o_dbg_last_seq <= w_seq;

                if (!w_type_ok) begin
                    o_type_err_sticky <= 1'b1;
                end
                else if (!w_channel_ok) begin
                    o_channel_err_sticky <= 1'b1;
                end
                else if (!w_crc_ok) begin
                    o_crc_err_sticky <= 1'b1;
                end
                else begin
                    // type/channel/crc 正确，输出一个字节
                    o_byte_data  <= w_data;
                    o_byte_valid <= 1'b1;

                    // seq 检查
                    if (!w_seq_ok)
                        o_seq_err_sticky <= 1'b1;

                    // 无论 seq 是否连续，都重同步期望值到当前 seq+1
                    r_expected_seq       <= w_seq + 8'd1;
                    r_expected_seq_valid <= 1'b1;
                    o_dbg_expected_seq   <= w_seq + 8'd1;
                end
            end
        end
    end

endmodule