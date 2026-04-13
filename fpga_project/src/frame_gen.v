
`timescale 1 ns / 1 ps
`define LANE_WIDTH 1
`define LANE_DATA_WIDTH 32

module frame_gen
 (
    reg0x0007,
    reg0x0008,
    reg0x0009,
    reg0x000A,
    reg0x000B,
    reg0x000C,
    reg0x000D,
    reg0x000E,
    reg0x000F,

    // User Interface
    TX_D,  
    TX_REM,   
    TX_SOF_N,     
    TX_EOF_N,
    TX_SRC_RDY_N,
    TX_DST_RDY_N,

    // System Interface
    USER_CLK,      
    RESET,
    CHANNEL_UP
);

//*****************************Parameter Declarations****************************
    parameter            DATA_WIDTH      = `LANE_DATA_WIDTH * `LANE_WIDTH;
    localparam           REM_WIDTH       =  ((DATA_WIDTH/8-1) > 1) ? $clog2(DATA_WIDTH/8-1) : 1; 

//***********************************Port Declarations*******************************
input [31:0]                reg0x0007;
input [31:0]                reg0x0008;
input [31:0]                reg0x0009;
input [31:0]                reg0x000A;
input [31:0]                reg0x000B;
input [31:0]                reg0x000C;
input [31:0]                reg0x000D;
input [31:0]                reg0x000E;
input [31:0]                reg0x000F;

   // User Interface
output  [0:DATA_WIDTH-1]     TX_D;
output  [0:REM_WIDTH-1]      TX_REM;
output                       TX_SOF_N;
output                       TX_EOF_N;                   
output                       TX_SRC_RDY_N;
input                        TX_DST_RDY_N;

      // System Interface
input                        USER_CLK;
input                        RESET; 
input                        CHANNEL_UP;

//***************************External Register Declarations***************************
reg                          TX_SRC_RDY_N;      
reg                          TX_SOF_N;
reg                          TX_EOF_N;    

//***************************Internal Register Declarations***************************
reg     [0:15]               data_lfsr_r;              
reg     [0:7]                frame_size_r;
reg     [0:7]                bytes_sent_r;                                           
reg     [0:3]                ifg_size_r;
    //State registers for one-hot state machine
reg                          idle_r;
reg                          single_cycle_frame_r;
reg                          sof_r;
reg                          data_cycle_r;
reg                          eof_r;                         
wire                         reset_c;
//*********************************Wire Declarations**********************************
wire                         ifg_done_c;
    //Next state signals for one-hot state machine
wire                         next_idle_c;
wire                         next_single_cycle_frame_c;
wire                         next_sof_c;
wire                         next_data_cycle_c;
wire                         next_eof_c;

wire                        dly_data_xfer;
reg [4:0]                   channel_up_cnt;
reg                         data_test_en;
reg [31:0]                  data_test;

//*********************************Main Body of Code**********************************
  always @ (posedge USER_CLK)
  begin
    if(RESET)
        channel_up_cnt <=  5'd0;
    else if(CHANNEL_UP)
      if(&channel_up_cnt)
        channel_up_cnt <=  channel_up_cnt;
      else 
        channel_up_cnt <=  channel_up_cnt + 1'b1;
    else
      channel_up_cnt <=  5'd0;
  end

  assign dly_data_xfer = (&channel_up_cnt);

  //Generate RESET signal when Aurora channel is not ready
  assign reset_c = RESET || !dly_data_xfer;

    //______________________________ Transmit Data  __________________________________   
    //Generate random data using XNOR feedback LFSR
    always @(posedge USER_CLK)
        if(reset_c)
        begin
            data_lfsr_r          <=      16'hABCD;  //random seed value
        end
        else if(!TX_DST_RDY_N && !idle_r)
        begin
            data_lfsr_r          <=      {!{data_lfsr_r[3]^data_lfsr_r[12]^data_lfsr_r[14]^data_lfsr_r[15]},
                                data_lfsr_r[0:14]};
        end
  
    //Connect TX_D to the DATA LFSR or UFC LFSR based on TX_DST_RDY_N and UFC FSM control signals
    always @(posedge USER_CLK) begin
        data_test_en          <=      reg0x0007[0]; 
        data_test             <=      reg0x0008;///{reg0x000F,reg0x000E,reg0x000D,reg0x000C,reg0x000B,reg0x000A,reg0x0009,reg0x0008}; 
    end

    //Connect TX_D to the DATA LFSR
    assign  TX_D    =   data_test_en ? data_test : {DATA_WIDTH/16{data_lfsr_r}};

    //Tie DATA LFSR to REM to generate random words
    assign  TX_REM  = (DATA_WIDTH <= 128) ? data_lfsr_r[0:REM_WIDTH-1] : (DATA_WIDTH/8 -1);

    //Use a counter to determine the size of the next frame to send
    always @(posedge USER_CLK)
        if(reset_c)  
            frame_size_r    <=      8'h00;
        else if(single_cycle_frame_r || eof_r)
            frame_size_r    <=      frame_size_r + 1'b1;
           
    //Use a second counter to determine how many bytes of the frame have already been sent
    always @(posedge USER_CLK)
        if(reset_c)
            bytes_sent_r    <=      8'h00;
        else if(sof_r)
            bytes_sent_r    <=      8'h01;
        else if(!TX_DST_RDY_N && !idle_r)
            bytes_sent_r    <=      bytes_sent_r + 1'b1;
   
    //Use a freerunning counter to determine the IFG
    always @(posedge USER_CLK)
        if(reset_c)
            ifg_size_r      <=      4'h0;
        else
            ifg_size_r      <=      ifg_size_r + 1'b1;
           
    //IFG is done when ifg_size register is 0
    assign  ifg_done_c  =   (ifg_size_r == 4'h0);   

    //_____________________________ Framing State machine______________________________
    //Use a state machine to determine whether to start a frame, end a frame, send
    //data or send nothing
   
    //State registers for 1-hot state machine
    always @(posedge USER_CLK)
        if(reset_c)
        begin
            idle_r                  <=      1'b1;
            single_cycle_frame_r    <=      1'b0;
            sof_r                   <=      1'b0;
            data_cycle_r            <=      1'b0;
            eof_r                   <=      1'b0;
        end
        else if(!TX_DST_RDY_N)
        begin
            idle_r                  <=      next_idle_c;
            single_cycle_frame_r    <=      next_single_cycle_frame_c;
            sof_r                   <=      next_sof_c;
            data_cycle_r            <=      next_data_cycle_c;
            eof_r                   <=      next_eof_c;
        end
       
       
    //Nextstate logic for 1-hot state machine
    assign  next_idle_c                 =   !ifg_done_c &&
                                            (single_cycle_frame_r || eof_r || idle_r);
   
    assign  next_single_cycle_frame_c   =   (ifg_done_c && (frame_size_r == 0)) &&
                                            (idle_r || single_cycle_frame_r || eof_r);
                                           
    assign  next_sof_c                  =   (ifg_done_c && (frame_size_r != 0)) &&
                                            (idle_r || single_cycle_frame_r || eof_r);
                                           
    assign  next_data_cycle_c           =   (frame_size_r != bytes_sent_r) &&
                                            (sof_r || data_cycle_r);
                                           
    assign  next_eof_c                  =   (frame_size_r == bytes_sent_r) &&
                                            (sof_r || data_cycle_r);
   
   
    //Output logic for 1-hot state machine
    always @(posedge USER_CLK)
        if(reset_c)
        begin
            TX_SOF_N        <=      1'b1;
            TX_EOF_N        <=      1'b1;
            TX_SRC_RDY_N    <=      1'b1;   
        end
        else if(!TX_DST_RDY_N)
        begin
            TX_SOF_N        <=      !(sof_r || single_cycle_frame_r);
            TX_EOF_N        <=      !(eof_r || single_cycle_frame_r);
            TX_SRC_RDY_N    <=      idle_r;
        end       
   
 
 endmodule 
