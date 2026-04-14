`timescale 1ns / 1ps

module rx_packet_monitor_v1_0
(
    input               i_clk,
    input               i_rst_n,

    input       [7:0]   i_dbg_rx_pkt_type,
    input       [7:0]   i_dbg_rx_seq,
    input               i_dbg_rx_hdr_crc_ok,
    input               i_dbg_rx_crc32_ok,
    input               i_dbg_rx_err_sticky,
    input       [3:0]   i_dbg_rx_state,

    output  reg         o_hdr_seen_sticky,
    output  reg         o_good_pkt_seen_sticky,
    output  reg         o_err_seen_sticky,
    output  reg         o_drop_seen_sticky,

    output  reg [31:0]  o_hdr_ok_cnt,
    output  reg [31:0]  o_crc_ok_cnt,
    output  reg [31:0]  o_good_fs_cnt,
    output  reg [31:0]  o_good_pay_cnt,
    output  reg [31:0]  o_good_fe_cnt,

    output  reg [7:0]   o_last_good_type,
    output  reg [7:0]   o_last_good_seq
);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_hdr_seen_sticky      <= 1'b0;
            o_good_pkt_seen_sticky <= 1'b0;
            o_err_seen_sticky      <= 1'b0;
            o_drop_seen_sticky     <= 1'b0;

            o_hdr_ok_cnt           <= 32'd0;
            o_crc_ok_cnt           <= 32'd0;
            o_good_fs_cnt          <= 32'd0;
            o_good_pay_cnt         <= 32'd0;
            o_good_fe_cnt          <= 32'd0;

            o_last_good_type       <= 8'd0;
            o_last_good_seq        <= 8'd0;
        end
        else begin
            if (i_dbg_rx_hdr_crc_ok) begin
                o_hdr_seen_sticky <= 1'b1;
                o_hdr_ok_cnt      <= o_hdr_ok_cnt + 32'd1;
            end

            if (i_dbg_rx_crc32_ok) begin
                o_good_pkt_seen_sticky <= 1'b1;
                o_crc_ok_cnt           <= o_crc_ok_cnt + 32'd1;
                o_last_good_type       <= i_dbg_rx_pkt_type;
                o_last_good_seq        <= i_dbg_rx_seq;

                case (i_dbg_rx_pkt_type)
                    8'h01: o_good_fs_cnt  <= o_good_fs_cnt  + 32'd1;
                    8'h11: o_good_pay_cnt <= o_good_pay_cnt + 32'd1;
                    8'h21: o_good_fe_cnt  <= o_good_fe_cnt  + 32'd1;
                    default: begin end
                endcase
            end

            if (i_dbg_rx_err_sticky)
                o_err_seen_sticky <= 1'b1;

            if (i_dbg_rx_state == 4'd6)
                o_drop_seen_sticky <= 1'b1;
        end
    end

endmodule