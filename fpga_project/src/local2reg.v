
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


module local2reg
(

	input             cfg_clk_i       ,
	input             cfg_rstn_i      ,
	input             local_wren_i    ,
	input [15:0]      local_addr_i    ,
	input [3 :0]      local_strb_i    ,
	input             local_rden_i    ,
	input [31:0]      local_wdat_i    ,
	output reg [31:0] local_rdat_o    ,
	output            local_rdat_vld_o,
	output            local_wdat_rdy_o,
	
////////user signal
	
	output reg [31:0] reg0x0000,input [31:0] mon0x0010,
	output reg [31:0] reg0x0001,input [31:0] mon0x0011,
	output reg [31:0] reg0x0002,input [31:0] mon0x0012,
    output reg [31:0] reg0x0003,input [31:0] mon0x0013,
    output reg [31:0] reg0x0004,input [31:0] mon0x0014,
    output reg [31:0] reg0x0005,input [31:0] mon0x0015,
    output reg [31:0] reg0x0006,input [31:0] mon0x0016,
    output reg [31:0] reg0x0007,input [31:0] mon0x0017,
    output reg [31:0] reg0x0008,input [31:0] mon0x0018,
    output reg [31:0] reg0x0009,input [31:0] mon0x0019,
    output reg [31:0] reg0x000A,input [31:0] mon0x001A,
    output reg [31:0] reg0x000B,input [31:0] mon0x001B,
    output reg [31:0] reg0x000C,input [31:0] mon0x001C,
    output reg [31:0] reg0x000D,input [31:0] mon0x001D,
    output reg [31:0] reg0x000E,input [31:0] mon0x001E,
    output reg [31:0] reg0x000F,input [31:0] mon0x001F
);
  


/////////////////////////////////////
//user design
/////////////////////////////////////

always @(posedge cfg_clk_i)
    if(local_wren_i && local_wdat_rdy_o)
    begin
        case(local_addr_i[7:0])  
        8'h00: reg0x0000 <= local_wdat_i ;
        8'h01: reg0x0001 <= local_wdat_i ;
        8'h02: reg0x0002 <= local_wdat_i ;
        8'h03: reg0x0003 <= local_wdat_i ;
        8'h04: reg0x0004 <= local_wdat_i ;
        8'h05: reg0x0005 <= local_wdat_i ;
        8'h06: reg0x0006 <= local_wdat_i ;
        8'h07: reg0x0007 <= local_wdat_i ;
        8'h08: reg0x0008 <= local_wdat_i ;
        8'h09: reg0x0009 <= local_wdat_i ;
        8'h0A: reg0x000A <= local_wdat_i ;
        8'h0B: reg0x000B <= local_wdat_i ;
        8'h0C: reg0x000C <= local_wdat_i ;
        8'h0D: reg0x000D <= local_wdat_i ;
        8'h0E: reg0x000E <= local_wdat_i ;
        8'h0F: reg0x000F <= local_wdat_i ;
        endcase
    end


assign local_wdat_rdy_o = 1;

reg r_local_rden;
reg [9:0]r_dat_trig;

always @(posedge cfg_clk_i)
begin
    if(~cfg_rstn_i)
    begin
        r_local_rden <= 0;
        r_dat_trig <= 0;  
    end
    else
    begin
        r_local_rden <= local_rden_i;
        r_dat_trig[0]  <= (~r_local_rden) & local_rden_i;
        r_dat_trig[9:1] <= r_dat_trig[8:0];
   end
end

always @(posedge cfg_clk_i)
    if(~cfg_rstn_i)
    begin
        local_rdat_o <= 32'h0;
    end
    else
    begin
        case(local_addr_i[13:0])
		//read and write	
        8'h00: local_rdat_o <= reg0x0000 ;
        8'h01: local_rdat_o <= reg0x0001 ;
        8'h02: local_rdat_o <= reg0x0002 ;
        8'h03: local_rdat_o <= reg0x0003 ;
        8'h04: local_rdat_o <= reg0x0004 ;
        8'h05: local_rdat_o <= reg0x0005 ;
        8'h06: local_rdat_o <= reg0x0006 ;
        8'h07: local_rdat_o <= reg0x0007 ;
        8'h08: local_rdat_o <= reg0x0008 ;
        8'h09: local_rdat_o <= reg0x0009 ;
        8'h0A: local_rdat_o <= reg0x000A ;
        8'h0B: local_rdat_o <= reg0x000B ;
        8'h0C: local_rdat_o <= reg0x000C ;
        8'h0D: local_rdat_o <= reg0x000D ;
        8'h0E: local_rdat_o <= reg0x000E ;
        8'h0F: local_rdat_o <= reg0x000F ;

        8'h10: local_rdat_o <= mon0x0010 ;
        8'h11: local_rdat_o <= mon0x0011 ;
        8'h12: local_rdat_o <= mon0x0012 ;
        8'h13: local_rdat_o <= mon0x0013 ;
        8'h14: local_rdat_o <= mon0x0014 ;
        8'h15: local_rdat_o <= mon0x0015 ;
        8'h16: local_rdat_o <= mon0x0016 ;
        8'h17: local_rdat_o <= mon0x0017 ;
        8'h18: local_rdat_o <= mon0x0018 ;
        8'h19: local_rdat_o <= mon0x0019 ;
        8'h1A: local_rdat_o <= mon0x001A ;
        8'h1B: local_rdat_o <= mon0x001B ;
        8'h1C: local_rdat_o <= mon0x001C ;
        8'h1D: local_rdat_o <= mon0x001D ;
        8'h1E: local_rdat_o <= mon0x001E ;
        8'h1F: local_rdat_o <= mon0x001F ;
	
		default:
		        begin
		            local_rdat_o <= 0;
		        end			
        endcase
    end

assign local_rdat_vld_o = r_dat_trig[1];
/////////////////////////////////////


endmodule
