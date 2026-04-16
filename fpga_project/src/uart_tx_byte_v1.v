
//==============================================================================
// uart_tx_byte_v1
// byte pulse -> UART TX
//==============================================================================
module uart_tx_byte_v1
#(
    parameter integer CLKS_PER_BIT = 678
)
(
    input            i_clk,
    input            i_rst_n,

    input      [7:0] i_byte_data,
    input            i_byte_valid,
    output           o_byte_ready,

    output reg       o_uart_tx,
    output reg       o_busy
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

    assign o_byte_ready = (state == S_IDLE);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state   <= S_IDLE;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
            data_reg<= 8'd0;
            o_uart_tx <= 1'b1;
            o_busy    <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    o_uart_tx <= 1'b1;
                    o_busy    <= 1'b0;
                    clk_cnt   <= 16'd0;
                    bit_idx   <= 3'd0;

                    if (i_byte_valid) begin
                        data_reg <= i_byte_data;
                        state    <= S_START;
                        o_busy   <= 1'b1;
                        o_uart_tx<= 1'b0; // start bit
                        clk_cnt  <= CLKS_PER_BIT - 1;
                    end
                end

                S_START: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        state   <= S_DATA;
                        bit_idx <= 3'd0;
                        o_uart_tx<= data_reg[0];
                        clk_cnt <= CLKS_PER_BIT - 1;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_DATA: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        if (bit_idx == 3'd7) begin
                            state    <= S_STOP;
                            o_uart_tx <= 1'b1; // stop bit
                            clk_cnt  <= CLKS_PER_BIT - 1;
                        end
                        else begin
                            bit_idx   <= bit_idx + 3'd1;
                            o_uart_tx <= data_reg[bit_idx + 3'd1];
                            clk_cnt   <= CLKS_PER_BIT - 1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                S_STOP: begin
                    o_busy <= 1'b1;
                    if (clk_cnt == 16'd0) begin
                        state    <= S_IDLE;
                        o_uart_tx<= 1'b1;
                        o_busy   <= 1'b0;
                    end
                    else begin
                        clk_cnt <= clk_cnt - 16'd1;
                    end
                end

                default: begin
                    state    <= S_IDLE;
                    o_uart_tx<= 1'b1;
                    o_busy   <= 1'b0;
                end
            endcase
        end
    end

endmodule