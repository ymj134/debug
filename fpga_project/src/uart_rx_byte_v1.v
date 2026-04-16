
//==============================================================================
// uart_rx_byte_v1
// UART RX -> byte pulse
//==============================================================================
module uart_rx_byte_v1
#(
    parameter integer CLKS_PER_BIT = 678
)
(
    input           i_clk,
    input           i_rst_n,
    input           i_uart_rx,

    output reg [7:0] o_byte_data,
    output reg       o_byte_valid
);

    localparam [2:0]
        S_IDLE  = 3'd0,
        S_START = 3'd1,
        S_DATA  = 3'd2,
        S_STOP  = 3'd3;

    reg [2:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;

    reg rx_meta, rx_sync;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= i_uart_rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 16'd0;
            bit_idx    <= 3'd0;
            data_reg   <= 8'd0;
            o_byte_data<= 8'd0;
            o_byte_valid <= 1'b0;
        end
        else begin
            o_byte_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (!rx_sync) begin
                        state   <= S_START;
                        clk_cnt <= (CLKS_PER_BIT >> 1);
                    end
                end

                S_START: begin
                    if (clk_cnt == 16'd0) begin
                        if (!rx_sync) begin
                            state   <= S_DATA;
                            clk_cnt <= CLKS_PER_BIT - 1;
                            bit_idx <= 3'd0;
                        end
                        else begin
                            state <= S_IDLE;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_DATA: begin
                    if (clk_cnt == 16'd0) begin
                        data_reg[bit_idx] <= rx_sync;
                        clk_cnt <= CLKS_PER_BIT - 1;

                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end
                        else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == 16'd0) begin
                        o_byte_data  <= data_reg;
                        o_byte_valid <= 1'b1;
                        state        <= S_IDLE;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

