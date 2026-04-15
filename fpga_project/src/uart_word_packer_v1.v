`timescale 1ns / 1ps

/*********************************************************************************
* Module       : uart_word_packer_v1
* Description  :
*   将 UART 字节打成 32-bit 控制字，供 TX_CTRL_FIFO 使用
*
* Word format:
*   [31:27] = 5'b10000   // UART_DATA tag
*   [26:24] = channel_id
*   [23:16] = seq
*   [15:8]  = uart_data
*   [7:0]   = crc8(type_byte, seq, uart_data)
*
* Notes:
*   1) 本模块默认输入字节已经在 i_clk 域
*   2) 当 i_byte_valid=1 且 i_word_ready=1 时，输出一个有效 word
*   3) 当 i_byte_valid=1 但 i_word_ready=0 时，当前字节会被丢弃，并拉高 overflow sticky
*********************************************************************************/

module uart_word_packer_v1
#(
    parameter [2:0] CHANNEL_ID = 3'b000
)
(
    input               i_clk,
    input               i_rst_n,

    // 上游 UART byte 输入（需已同步到 i_clk 域）
    input       [7:0]   i_byte_data,
    input               i_byte_valid,

    // 下游是否可接收，一般接 ~tx_ctrl_fifo_full
    input               i_word_ready,

    output reg  [31:0]  o_word_data,
    output reg          o_word_valid,

    output reg  [7:0]   o_dbg_seq,
    output reg          o_overflow_sticky
);

    localparam [4:0] UART_DATA_TAG = 5'b10000;

    reg [7:0] r_seq;

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

    wire [7:0] w_type_byte;
    wire [7:0] w_crc8;

    assign w_type_byte = {UART_DATA_TAG, CHANNEL_ID};
    assign w_crc8      = f_crc8_word_fields(w_type_byte, r_seq, i_byte_data);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_seq             <= 8'd0;
            o_word_data       <= 32'd0;
            o_word_valid      <= 1'b0;
            o_dbg_seq         <= 8'd0;
            o_overflow_sticky <= 1'b0;
        end
        else begin
            o_word_valid <= 1'b0;

            if (i_byte_valid) begin
                if (i_word_ready) begin
                    o_word_data  <= {UART_DATA_TAG, CHANNEL_ID, r_seq, i_byte_data, w_crc8};
                    o_word_valid <= 1'b1;
                    o_dbg_seq    <= r_seq;
                    r_seq        <= r_seq + 8'd1;
                end
                else begin
                    o_overflow_sticky <= 1'b1;
                end
            end
        end
    end

endmodule