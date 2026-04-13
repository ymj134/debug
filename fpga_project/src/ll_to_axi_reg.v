
`timescale 1 ns/1 ps

 module ll_to_axi_reg #
 (
    parameter            DATA_WIDTH         = 16, // DATA bus width
    parameter            STRB_WIDTH         = 2, // STROBE bus width
    parameter            USE_UFC_REM        = 0, // UFC REM bus width identifier
    parameter            USE_4_NFC          = 0, // 0 => PDU, 1 => NFC, 2 => UFC 
    parameter            BC                 =  DATA_WIDTH>>3, //Byte count
    parameter            REM_WIDTH          = 1 // REM bus width    
 )
 ( 
    // LocalLink input Interface
    LL_IP_DATA,
    LL_IP_SOF_N,
    LL_IP_EOF_N,
    LL_IP_REM,
    LL_IP_SRC_RDY_N,
    LL_OP_DST_RDY_N,
 
    // AXI4-S output signals
    AXI4_S_OP_TVALID,
    AXI4_S_OP_TDATA,
    AXI4_S_OP_TKEEP,
    AXI4_S_OP_TLAST,
    AXI4_S_IP_TREADY

);

 //***********************************Port Declarations******************************* 
    // AXI4-Stream TX Interface
    output     [(DATA_WIDTH-1):0]     AXI4_S_OP_TDATA;
    output     [(STRB_WIDTH-1):0]     AXI4_S_OP_TKEEP;
    output                            AXI4_S_OP_TVALID;
    output                            AXI4_S_OP_TLAST;
    input                             AXI4_S_IP_TREADY;


    // LocalLink TX Interface
    input      [0:(DATA_WIDTH-1)]     LL_IP_DATA;
    input      [0:(REM_WIDTH-1)]      LL_IP_REM;
    input                             LL_IP_SOF_N;
    input                             LL_IP_EOF_N;
    input                             LL_IP_SRC_RDY_N;
    output                            LL_OP_DST_RDY_N;

    wire     [0:(STRB_WIDTH-1)]       AXI4_S_OP_TKEEP_i;

//*********************************Main Body of Code**********************************
generate
if(USE_4_NFC==1)
begin
  genvar i;
  for (i=0; i<DATA_WIDTH; i=i+1) begin: nfc
    assign AXI4_S_OP_TDATA[i] = LL_IP_DATA[(DATA_WIDTH-1)-i];
end
end
endgenerate

generate
if(USE_4_NFC==2)
begin
  genvar i;
  for (i=0; i<DATA_WIDTH; i=i+1) begin: ufc
    assign AXI4_S_OP_TDATA[i] = LL_IP_DATA[(DATA_WIDTH-1)-i];
end
end
endgenerate

generate
if(USE_4_NFC==0)
begin
  genvar i;
  for (i=0; i<BC; i=i+1) begin: pdu
    assign AXI4_S_OP_TDATA[((BC-1-i)*8)+7:((BC-1-i)*8)] = LL_IP_DATA[((BC-1-i)*8):((BC-1-i)*8)+7];
end
end
endgenerate

generate
  genvar j;
  for (j=0; j<STRB_WIDTH; j=j+1) begin: strb
    assign AXI4_S_OP_TKEEP[j] = AXI4_S_OP_TKEEP_i[j];
  end
endgenerate

   assign AXI4_S_OP_TVALID = !LL_IP_SRC_RDY_N;
   assign AXI4_S_OP_TLAST  = !LL_IP_EOF_N;

    assign AXI4_S_OP_TKEEP_i  = (LL_IP_REM == {REM_WIDTH{1'b1}})? ({STRB_WIDTH{1'b1}}) :
                             (~({STRB_WIDTH{1'b1}}>>(LL_IP_REM + 1'b1)));

   assign LL_OP_DST_RDY_N  = !AXI4_S_IP_TREADY;

endmodule
