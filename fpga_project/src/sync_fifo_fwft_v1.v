//==============================================================================
// sync_fifo_fwft_v1
// Simple synchronous FWFT / Show-Ahead FIFO
//==============================================================================
module sync_fifo_fwft_v1
#(
    parameter integer DATA_W = 32,
    parameter integer DEPTH  = 64,
    parameter integer ADDR_W = 6
)
(
    input                   i_clk,
    input                   i_rst_n,

    input                   i_wr_en,
    input      [DATA_W-1:0] i_din,
    output                  o_full,

    input                   i_rd_en,
    output     [DATA_W-1:0] o_dout,
    output                  o_empty,
    output     [ADDR_W:0]   o_count
);

    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] wptr;
    reg [ADDR_W-1:0] rptr;
    reg [ADDR_W:0]   count;

    wire do_write = i_wr_en && !o_full;
    wire do_read  = i_rd_en && !o_empty;

    assign o_empty = (count == { (ADDR_W+1){1'b0} });
    assign o_full  = (count == DEPTH[ADDR_W:0]);
    assign o_count = count;
    assign o_dout  = mem[rptr];

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            wptr  <= {ADDR_W{1'b0}};
            rptr  <= {ADDR_W{1'b0}};
            count <= {(ADDR_W+1){1'b0}};
        end
        else begin
            if (do_write) begin
                mem[wptr] <= i_din;
                wptr      <= wptr + {{(ADDR_W-1){1'b0}},1'b1};
            end

            if (do_read) begin
                rptr <= rptr + {{(ADDR_W-1){1'b0}},1'b1};
            end

            case ({do_write, do_read})
                2'b10: count <= count + {{ADDR_W{1'b0}},1'b1};
                2'b01: count <= count - {{ADDR_W{1'b0}},1'b1};
                default: count <= count;
            endcase
        end
    end

endmodule