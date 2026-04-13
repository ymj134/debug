
`timescale 1 ns/1 ps

module axi_to_ll_reg #
(
   parameter            DATA_WIDTH         = 16, // DATA bus width
   parameter            STRB_WIDTH         = 2, // STROBE bus width
   parameter            BC                 = DATA_WIDTH/8, //Byte count
   parameter            USE_4_NFC          = 0, // 0 => PDU, 1 => NFC, 2 => UFC
   parameter            REM_WIDTH          = 1 // REM bus width
)
( 
   // AXI4-S input signals
   AXI4_S_IP_TX_TVALID,
   AXI4_S_IP_TX_TREADY,
   AXI4_S_IP_TX_TDATA,
   AXI4_S_IP_TX_TKEEP,
   AXI4_S_IP_TX_TLAST,

   // LocalLink output Interface
   LL_OP_DATA,
   LL_OP_SOF_N,
   LL_OP_EOF_N,
   LL_OP_REM,
   LL_OP_SRC_RDY_N,
   LL_IP_DST_RDY_N,

   // System Interface
   USER_CLK,
   RESET,    
   CHANNEL_UP

);

 //***********************************Port Declarations******************************* 
    // AXI4-Stream Interface
    input   [(DATA_WIDTH-1):0]     AXI4_S_IP_TX_TDATA;
    input   [(STRB_WIDTH-1):0]     AXI4_S_IP_TX_TKEEP;
    input                          AXI4_S_IP_TX_TVALID;
    input                          AXI4_S_IP_TX_TLAST;
    output                         AXI4_S_IP_TX_TREADY;

    // LocalLink TX Interface
    output reg [0:(DATA_WIDTH-1)]  LL_OP_DATA;
    output reg [0:(REM_WIDTH-1)]   LL_OP_REM;
    output reg                     LL_OP_SRC_RDY_N;
    output reg                     LL_OP_SOF_N;
    output reg                     LL_OP_EOF_N;
    input                          LL_IP_DST_RDY_N;

    // System Interface
    input                          USER_CLK;
    input                          RESET;
    input                          CHANNEL_UP;


    reg                            new_pkt_r;

    wire                           new_pkt;
    wire   [0:(STRB_WIDTH-1)]      AXI4_S_IP_TX_TKEEP_i;

//*********************************Main Body of Code**********************************

   assign AXI4_S_IP_TX_TREADY = !LL_IP_DST_RDY_N;

generate
  genvar i;
  for (i=0; i<BC; i=i+1) begin: pdu
    always @ (posedge USER_CLK)
    begin
      LL_OP_DATA[((BC-1-i)*8):((BC-1-i)*8)+7] = AXI4_S_IP_TX_TDATA[((BC-1-i)*8)+7:((BC-1-i)*8)];
    end
  end
endgenerate

generate
  genvar j;
  for (j=0; j<STRB_WIDTH; j=j+1) begin: strb
    assign AXI4_S_IP_TX_TKEEP_i[j] = AXI4_S_IP_TX_TKEEP[j];
  end
endgenerate

    always @ (posedge USER_CLK)
    begin
      LL_OP_REM = (AXI4_S_IP_TX_TKEEP_i[0] + AXI4_S_IP_TX_TKEEP_i[1] + AXI4_S_IP_TX_TKEEP_i[2] + AXI4_S_IP_TX_TKEEP_i[3]) - 1'b1;
    end

    always @ (posedge USER_CLK)
    begin
      LL_OP_SRC_RDY_N = !AXI4_S_IP_TX_TVALID;
      LL_OP_EOF_N = !AXI4_S_IP_TX_TLAST;
      LL_OP_SOF_N  = ~ ( ( AXI4_S_IP_TX_TVALID && AXI4_S_IP_TX_TREADY && AXI4_S_IP_TX_TLAST ) ? ((new_pkt_r) ? 1'b0 : 1'b1) : (new_pkt && (!new_pkt_r)));
    end

   assign new_pkt = ( AXI4_S_IP_TX_TVALID && AXI4_S_IP_TX_TREADY && AXI4_S_IP_TX_TLAST ) ? 1'b0 : ((AXI4_S_IP_TX_TVALID && AXI4_S_IP_TX_TREADY && !AXI4_S_IP_TX_TLAST ) ? 1'b1 : new_pkt_r);
  

always @ (posedge USER_CLK)
begin
  if(RESET)
    new_pkt_r <=  1'b0;
  else if(CHANNEL_UP)
    new_pkt_r <=  new_pkt;
  else
    new_pkt_r <=  1'b0;
end

endmodule
