


`timescale 1ns / 1ps


module reset_gen (

    input i_clk1,
    input i_lock,
    output reg o_rst1 = 1

);

reg [11:0]r_cnt = 0;

always @(posedge i_clk1)
begin
    if(i_lock == 1'b0)
    begin
        r_cnt <= 12'b0;
    end
    else if(r_cnt < 12'hfff)
    begin
        r_cnt <= r_cnt + 1'b1;
    end


    if(r_cnt == 12'hfff)
        o_rst1 <= 1'b0;
    else
        o_rst1 <= 1'b1;

end







endmodule
