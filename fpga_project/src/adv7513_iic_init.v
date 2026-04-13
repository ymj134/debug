
`timescale 1ns/1ps

`define IF_DATA_WIDTH 8

module adv7513_iic_init (
     I_CLK,   
	 I_RESETN,
	 start,
	 O_TX_EN, 
	 O_WADDR, 
	 O_WDATA, 
	 O_RX_EN,
	 O_RADDR, 
	 I_RDATA,	 
     cstate_flag,
     error_flag
);

 input                        I_CLK;
 input                        I_RESETN;
 input                        start; 
 output                       O_TX_EN;
 output [2:0]                 O_WADDR;
 output [`IF_DATA_WIDTH-1:0]  O_WDATA;   
 output                       O_RX_EN;  
 output [2:0]                 O_RADDR;
 input  [`IF_DATA_WIDTH-1:0]  I_RDATA;
 output                       error_flag;
 output                       cstate_flag; 
 
//////////////////////////////////////////////////////////////////////////
//	Internal Wires/Registers
 reg                          O_TX_EN;
 reg [2:0]                    O_WADDR;
 reg [`IF_DATA_WIDTH-1:0]     O_WDATA;
 reg                          O_RX_EN;
 reg [2:0]                    O_RADDR;  

//define reg address of IIC-Master
 parameter 	PRERLO_ADDR      = 3'b000;
 parameter 	PRERHI_ADDR      = 3'b001;
 parameter 	CTR_ADDR         = 3'b010;
 parameter 	TXR_ADDR         = 3'b011; 
 parameter 	RXR_ADDR         = 3'b011; 
 parameter 	CR_ADDR          = 3'b100; 
 parameter 	SR_ADDR          = 3'b100;

 parameter  TX_DATA     = 8'b00000110;  //1e: 30
 

 parameter	CLK_Div_L	= 8'h63;  //
 parameter	CLK_Div_H	= 8'h00;  //

 parameter	EN_IP		= 8'h80; 
 		                  
 parameter 	STA_WR_CR	= 8'h90;	//start+write_ack
 parameter 	WR_CR		= 8'h10; //write+ack
 parameter	STP_WR_CR	= 8'h50; //stop+write+ack
 parameter	STP_CR		= 8'h40; //stop+write+ack
                          
 parameter 	RD_CR		= 8'h20;//read+ack
 parameter 	STP_RD_NCR	= 8'h68;//stop+read+nack
 
 parameter 	RD      	= 1'b1;
 parameter 	WR     		= 1'b0;
 
//define the address of IIC-Slave device 
 parameter 	DEV_ADDR	= 7'b011_1001; //0x72--右移1位0x39
 
//状态机
parameter IDLE             = 8'd0;
parameter PERSCALE0_REG    = 8'd1;
parameter PERSCALE1_REG    = 8'd2;
parameter MASTER_EN_REG    = 8'd3;

parameter WR_DEVICE_ADDRW  = 8'd4;
parameter WR_CMD90         = 8'd5;
parameter WR_RDTIP01       = 8'd6;
parameter WR_REG_ADDR      = 8'd7; //addr
parameter WR_CMD10_1       = 8'd8;
parameter WR_RDTIP02       = 8'd9;
parameter WR_DATA          = 8'd10; //data
parameter WR_CMD50_2       = 8'd11;
parameter WR_RDTIP03       = 8'd12;

parameter RD_DEVICE_ADDRW  = 8'd13;
parameter RD_CMD90_1       = 8'd14;
parameter RD_RDTIP01       = 8'd15;
parameter RD_REG_ADDR      = 8'd16; //addr
parameter RD_CMD10_1       = 8'd17;
parameter RD_RDTIP02       = 8'd18;
parameter RD_DEVICE_ADDRR  = 8'd19;
parameter RD_CMD90_2       = 8'd20;
parameter RD_RDTIP03       = 8'd21;
parameter RD_CMD20         = 8'd22;
parameter RD_RDTIP04       = 8'd23;
parameter RD_DATA          = 8'd24; //data
parameter RD_CMD68         = 8'd25;
parameter RD_RDTIP05       = 8'd26;

reg [7:0] state;
 
 reg[1:0]	wr_reg;
 reg[1:0]	rd_reg;

 reg[1:0]	wr_rd_stop;
 
 
 reg[7:0]	sr_data0;
 
 reg        error_reg  /* synthesis syn_keep=1 */;
 
 reg        start_dl;
 reg        start_d2;
 reg        start_d3;

//-------------------------------------------------------------------
localparam NUM = 14;
 wire [7:0] addr_mem [0:NUM]; 
 wire [7:0] data_mem [0:NUM];
 
 reg  [7:0] mem_cnt;

//-------------------------------------------------------------------
assign addr_mem[  0] = 8'h41; assign data_mem[  0] = 8'h10; 
assign addr_mem[  1] = 8'h98; assign data_mem[  1] = 8'h03; 
assign addr_mem[  2] = 8'h9A; assign data_mem[  2] = 8'hE0; 
assign addr_mem[  3] = 8'h9C; assign data_mem[  3] = 8'h30; 
assign addr_mem[  4] = 8'h9D; assign data_mem[  4] = 8'h61; 
assign addr_mem[  5] = 8'hA2; assign data_mem[  5] = 8'hA4; 
assign addr_mem[  6] = 8'hA3; assign data_mem[  6] = 8'hA4; 
assign addr_mem[  7] = 8'hE0; assign data_mem[  7] = 8'hD0; 
assign addr_mem[  8] = 8'hF9; assign data_mem[  8] = 8'h00; 
assign addr_mem[  9] = 8'h15; assign data_mem[  9] = 8'h00; 
assign addr_mem[ 10] = 8'h16; assign data_mem[ 10] = 8'h38; 
assign addr_mem[ 11] = 8'h17; assign data_mem[ 11] = 8'h02; 
assign addr_mem[ 12] = 8'h18; assign data_mem[ 12] = 8'h46; 
assign addr_mem[ 13] = 8'hAF; assign data_mem[ 13] = 8'h04; 
assign addr_mem[ 14] = 8'h97; assign data_mem[ 14] = 8'h00; 

always @(posedge I_CLK or negedge I_RESETN) 
begin
	if(!I_RESETN)
		mem_cnt <= 8'd0;
	else if(state == IDLE)
		mem_cnt <= 8'd0;
	else if(state == RD_RDTIP05 && rd_reg == 2'd3)
		mem_cnt <= mem_cnt + 1'b1;
	else
		mem_cnt <= mem_cnt;
end

//--------------------------------------------------------------------
always @(posedge I_CLK or negedge I_RESETN)
begin
	if(~I_RESETN)
		begin
			start_dl <= 1'b0;	
			start_d2 <= 1'b0;
			start_d3 <= 1'b0;
		end 
	else
		begin
			start_dl <= start;
			start_d2 <= start_dl;
			start_d3 <= start_d2;
		end
end		

////////////////////////////////////////////////////
assign error_flag=error_reg;
assign cstate_flag = 1'b0;
////////////////////////////////////////////////////


//--------------------------------------------------------------------
//状态机
//状态跳转
always @(posedge I_CLK or negedge I_RESETN) 
begin
	if(!I_RESETN)
		state <= IDLE;
	else 
		begin
			case(state)
				IDLE:
					begin
						if((start_d3 == 1'b0) && (start_d2 == 1'b1))  //start rising edge
							state <= PERSCALE0_REG;
						else
							state <= IDLE;
					end
				PERSCALE0_REG:
					begin
						if(wr_reg == 2'd2)
							state <= PERSCALE1_REG;
						else
							state <= PERSCALE0_REG;
					end
				PERSCALE1_REG:
					begin
						if(wr_reg == 2'd2)
							state <= MASTER_EN_REG;
						else
							state <= PERSCALE1_REG;
					end
				MASTER_EN_REG:
					begin
						if(wr_reg == 2'd2)
							state <= WR_DEVICE_ADDRW;
						else
							state <= MASTER_EN_REG;
					end
				
				//写操作开始
				WR_DEVICE_ADDRW:
					begin
						if(wr_reg == 2'd2)
							state <= WR_CMD90;
						else
							state <= WR_DEVICE_ADDRW;
					end	
				WR_CMD90:
					begin
						if(wr_reg == 2'd2)
							state <= WR_RDTIP01;
						else
							state <= WR_CMD90;
					end	
				WR_RDTIP01:
					begin
						if(rd_reg == 2'd3)
							state <= WR_REG_ADDR;
						else
							state <= WR_RDTIP01;
					end	
				WR_REG_ADDR:
					begin
						if(wr_reg == 2'd2)
							state <= WR_CMD10_1;
						else
							state <= WR_REG_ADDR;
					end	
				WR_CMD10_1:
					begin
						if(wr_reg == 2'd2)
							state <= WR_RDTIP02;
						else
							state <= WR_CMD10_1;
					end	
				WR_RDTIP02:
					begin
						if(rd_reg == 2'd3)
							state <= WR_DATA;
						else
							state <= WR_RDTIP02;
					end	
				WR_DATA:
					begin
						if(wr_reg == 2'd2)
							state <= WR_CMD50_2;
						else
							state <= WR_DATA;
					end	
				WR_CMD50_2:
					begin
						if(wr_reg == 2'd2)
							state <= WR_RDTIP03;
						else
							state <= WR_CMD50_2;
					end	
				WR_RDTIP03:
					begin
						if(rd_reg == 2'd3)
							state <= RD_DEVICE_ADDRW;
						else
							state <= WR_RDTIP03;
					end	
				
				//读操作开始	
				RD_DEVICE_ADDRW:
					begin
						if(wr_reg == 2'd2)
							state <= RD_CMD90_1;
						else
							state <= RD_DEVICE_ADDRW;
					end	
				RD_CMD90_1:
					begin
						if(wr_reg == 2'd2)
							state <= RD_RDTIP01;
						else
							state <= RD_CMD90_1;
					end	
				RD_RDTIP01:
					begin
						if(rd_reg == 2'd3)
							state <= RD_REG_ADDR;
						else
							state <= RD_RDTIP01;
					end	
				RD_REG_ADDR:
					begin
						if(wr_reg == 2'd2)
							state <= RD_CMD10_1;
						else
							state <= RD_REG_ADDR;
					end	
				RD_CMD10_1:
					begin
						if(wr_reg == 2'd2)
							state <= RD_RDTIP02;
						else
							state <= RD_CMD10_1;
					end	
				RD_RDTIP02:
					begin
						if(rd_reg == 2'd3)
							state <= RD_DEVICE_ADDRR;
						else
							state <= RD_RDTIP02;
					end	
				RD_DEVICE_ADDRR:
					begin
						if(wr_reg == 2'd2)
							state <= RD_CMD90_2;
						else
							state <= RD_DEVICE_ADDRR;
					end	
				RD_CMD90_2:
					begin
						if(wr_reg == 2'd2)
							state <= RD_RDTIP03;
						else
							state <= RD_CMD90_2;
					end	
				RD_RDTIP03:
					begin
						if(rd_reg == 2'd3)
							state <= RD_CMD20;
						else
							state <= RD_RDTIP03;
					end	
				RD_CMD20:
					begin
						if(wr_reg == 2'd2)
							state <= RD_RDTIP04;
						else
							state <= RD_CMD20;
					end	
				RD_RDTIP04:
					begin
						if(rd_reg == 2'd3)
							state <= RD_DATA;
						else
							state <= RD_RDTIP04;
					end	
				RD_DATA: //读出数据
					begin
						if(wr_rd_stop == 2'd3)
							state <= RD_CMD68;
						else
							state <= RD_DATA;
					end	
				RD_CMD68:
					begin
						if(wr_reg == 2'd2)
							state <= RD_RDTIP05;
						else
							state <= RD_CMD68;
					end	
				RD_RDTIP05:
					begin
						if(rd_reg == 2'd3)
							begin
								if(mem_cnt>=NUM)
									state <= IDLE;
								else
									state <= WR_DEVICE_ADDRW;
							end
						else
							state <= RD_RDTIP05;
					end
				default:
					begin
						state <= IDLE;
					end	
			endcase
		end
end

//状态输出
always @(negedge I_RESETN or posedge I_CLK) 
begin
	if(~I_RESETN)
		begin
		    O_TX_EN <= 1'b0; 
		    O_WADDR <= {3{1'b0}}; 
		    O_WDATA <= {`IF_DATA_WIDTH{1'b0}}; 
		    O_RX_EN <= 1'b0;
		    O_RADDR <= {3{1'b0}};
			wr_reg <= 0;
			rd_reg <=0;
			sr_data0 <=0;
			wr_rd_stop <=0;
			error_reg <= 0;
		end
	else 
		begin
		    case(state)
				IDLE:
					begin
						O_TX_EN <= 1'b0; 
		    			O_WADDR <= {3{1'b0}}; 
		    			O_WDATA <= {`IF_DATA_WIDTH{1'b0}}; 
		    			O_RX_EN <= 1'b0;
		    			O_RADDR <= {3{1'b0}};
						wr_reg <= 0;
						rd_reg <=0;
						wr_rd_stop <=0;
						error_reg <= 0;
					end
				PERSCALE0_REG:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= PRERLO_ADDR; 
	        			      O_WDATA <= CLK_Div_L; 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end				
		    			endcase	
					end
				PERSCALE1_REG:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= PRERHI_ADDR; 
	        			      O_WDATA <= CLK_Div_H; 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end
				MASTER_EN_REG:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CTR_ADDR; 
	        			      O_WDATA <= EN_IP; 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end
				
				//写操作开始
				WR_DEVICE_ADDRW:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= {DEV_ADDR,WR}; 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_CMD90:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= STA_WR_CR; 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_RDTIP01:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				WR_REG_ADDR:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= addr_mem[mem_cnt]; //memory address 
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_CMD10_1:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= WR_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_RDTIP02:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				WR_DATA:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= data_mem[mem_cnt];
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_CMD50_2:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= STP_WR_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				WR_RDTIP03:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				
				//读操作开始	
				RD_DEVICE_ADDRW:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= {DEV_ADDR,WR};
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_CMD90_1:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= STA_WR_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_RDTIP01:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				RD_REG_ADDR:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= addr_mem[mem_cnt]; //memory address
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_CMD10_1:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= WR_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_RDTIP02:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				RD_DEVICE_ADDRR:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= TXR_ADDR; 
	        			      O_WDATA <= {DEV_ADDR,RD};
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_CMD90_2:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= STA_WR_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_RDTIP03:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				RD_CMD20:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= RD_CR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_RDTIP04:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end	
				RD_DATA: //读出数据
					begin
						case(wr_rd_stop)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= RXR_ADDR;
						  	  wr_rd_stop <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  wr_rd_stop <= 2; 
						  end
						2:
						  begin
						  	  sr_data0 <= I_RDATA;
						  	  wr_rd_stop <= 3;
						  end	
						3:
						  begin
						  	  wr_rd_stop <= 0;
						  	  if(sr_data0 == data_mem[mem_cnt])
            			      	error_reg <= 0;
            			      else
            			      	error_reg <= 1;
						  end		
						endcase
					end	
				RD_CMD68:
					begin
						case(wr_reg)
		    			0:
		    			  begin
	        			      O_TX_EN <= 1'b1; 
	        			      O_WADDR <= CR_ADDR; 
	        			      O_WDATA <= STP_RD_NCR;
		    			  	  wr_reg <= 1;
		    			  end
		    			1:
		    			  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 2; 
		    			  end
		    			2:
		    			  begin
		    			  	  wr_reg <= 0;
		    			  end
						default:
						  begin
		    			  	  O_TX_EN <= 1'b0;
		    			  	  O_WADDR <= 1'b0;
		    			  	  O_WDATA <= 0;
		    			  	  wr_reg <= 0;
            			  end			
		    			endcase
					end	
				RD_RDTIP05:
					begin
						case(rd_reg)
						0:
						  begin
	        			      O_RX_EN <= 1'b1;
	        			      O_RADDR <= SR_ADDR;
						  	  rd_reg  <= 1;
						  end
						1:
						  begin
	        			      O_RX_EN <= 1'b0;
						  	  rd_reg  <= 2; 
						  end
						2:
						  begin
						      if(~I_RDATA[1])
						  	  	  rd_reg <= 3;
						  	  else
						  	  	  rd_reg <= 0;				
						  end	
						3:
						  begin
						  	  rd_reg <= 0;
						  end		
						endcase
					end
				default:
					begin
						O_TX_EN <= 1'b0; 
		    			O_WADDR <= {3{1'b0}}; 
		    			O_WDATA <= {`IF_DATA_WIDTH{1'b0}}; 
		    			O_RX_EN <= 1'b0;
		    			O_RADDR <= {3{1'b0}};
						wr_reg <= 0;
						rd_reg <=0;
						wr_rd_stop <=0;
						error_reg <= 0;
					end	
			endcase
		end
end


endmodule					
