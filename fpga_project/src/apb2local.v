
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: guo.zy
// 
// Create Date:    16:38:18 07/09/2018 
// Design Name: 
// Module Name:    top 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////


module apb2local
(

	input           cfg_clk_i ,
	input           cfg_rstn_i,
	input  [17:0]   cfg_addr_i,
	input           cfg_sel_i ,
	input           cfg_ena_i ,
	input           cfg_wr_i  ,
	output reg [31:0]   cfg_rdata_o,
	input  [31:0]   cfg_wdata_i,
	output reg     cfg_rdy_o,
	input  [3:0]    cfg_strb_i,
	
	output          local_wren_o,
	output [15:0]   local_addr_o,
	output [3 :0]   local_strb_o,
	output          local_rden_o,
	output [31:0]   local_wdat_o,
	input  [31:0]   local_rdat_i,
	input           local_rdat_vld_i,
    input           local_wdat_rdy_i

);
  


assign local_wren_o = cfg_ena_i & cfg_wr_i & cfg_sel_i;
assign local_addr_o = cfg_addr_i[17:2];
assign local_wdat_o = cfg_wdata_i;
assign local_rden_o = cfg_ena_i & (~cfg_wr_i) & cfg_sel_i;
assign local_strb_o = cfg_strb_i;



always @(*)
begin
    if(cfg_ena_i & (~cfg_wr_i) & cfg_sel_i)
		cfg_rdata_o = local_rdat_i ;
	else
		cfg_rdata_o = 0;
end

	
always @(*)
begin
    if(cfg_ena_i & cfg_wr_i & cfg_sel_i)
    begin
        cfg_rdy_o = local_wdat_rdy_i;
    end
	else if(cfg_ena_i & (~cfg_wr_i) & cfg_sel_i)
	begin
        cfg_rdy_o = local_rdat_vld_i;
	end
	else
	begin
		cfg_rdy_o = 0;
	end
end









endmodule
