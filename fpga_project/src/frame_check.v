
`timescale 1 ns / 1 ps

`define LANE_WIDTH 1
`define LANE_DATA_WIDTH 32

module frame_check
(
    // User Interface
    RX_D,  
    RX_REM,
    RX_SOF_N,
    RX_EOF_N,
    RX_SRC_RDY_N,

    // System Interface
    USER_CLK,      
    RESET,
    CHANNEL_UP,

    ERR_COUNT
);
parameter  DATA_WIDTH          = `LANE_DATA_WIDTH * `LANE_WIDTH;
localparam REM_WIDTH           =  ((DATA_WIDTH/8-1) > 1) ? $clog2(DATA_WIDTH/8-1) : 1; 

//***********************************Port Declarations*******************************
    // User Interface
input   [0:DATA_WIDTH-1]     RX_D;
input   [0:REM_WIDTH-1]      RX_REM;
input                        RX_SOF_N;
input                        RX_EOF_N;                    
input                        RX_SRC_RDY_N;

    // System Interface
input                        USER_CLK;
input                        RESET; 
input                        CHANNEL_UP;

output  [0:7]                ERR_COUNT;

//***************************Internal Register Declarations***************************
// Slack registers
reg   [0:DATA_WIDTH-1]     RX_D_SLACK;
reg   [0:REM_WIDTH-1]      RX_REM_1SLACK;
reg   [0:REM_WIDTH-1]      RX_REM_2SLACK;
reg                        RX_SOF_N_SLACK;
reg                        RX_EOF_N_SLACK;                 
reg                        RX_SRC_RDY_N_SLACK;

reg     [0:8]              err_count_r = 9'd0;        
reg                        data_in_frame_r;
reg                        data_valid_r;
reg     [0:DATA_WIDTH-1]   RX_D_R;
reg     [0:DATA_WIDTH-1]   pdu_cmp_data_r;
    // RX Data registers
reg     [0:15]             data_lfsr_r;
   
//*********************************Wire Declarations**********************************
  
wire               reset_c;
wire    [0:DATA_WIDTH-1]     data_lfsr_concat_w;
wire               data_valid_c;
wire               data_in_frame_c;
   
wire               data_err_detected_c;
reg                data_err_detected_r;
   
//*********************************Main Body of Code**********************************

  //Generate RESET signal when Aurora channel is not ready
  assign reset_c = RESET;

// SLACK registers

always @ (posedge USER_CLK)
begin
  RX_D_SLACK          <=  RX_D;
  RX_SRC_RDY_N_SLACK  <=  RX_SRC_RDY_N;
  RX_REM_1SLACK       <=  RX_REM;
  RX_REM_2SLACK       <=  RX_REM;
  RX_SOF_N_SLACK      <=  RX_SOF_N;
  RX_EOF_N_SLACK      <=  RX_EOF_N;
end

    //______________________________ Capture incoming data ___________________________   
    //Data is valid when RX_SRC_RDY_N is asserted and data is arriving within a frame
    assign  data_valid_c    =   data_in_frame_c && !RX_SRC_RDY_N_SLACK;

    //Data is in a frame if it is a single cycle frame or a multi_cycle frame has started
    assign  data_in_frame_c  =   data_in_frame_r  ||  (!RX_SRC_RDY_N_SLACK && !RX_SOF_N_SLACK);

    //RX Data in the pdu_cmp_data_r register is valid
    //only if it was valid when captured and had no error
    always @(posedge USER_CLK)
        if(reset_c)  
           data_valid_r    <=      1'b0;
        else if(CHANNEL_UP)
           data_valid_r    <=      data_valid_c && !data_err_detected_c;
        else
           data_valid_r    <=      1'b0;
   
    //Start a multicycle frame when a frame starts without ending on the same cycle. End
    //the frame when an EOF is detected
    always @(posedge USER_CLK)
        if(reset_c)  
            data_in_frame_r  <=      1'b0;
        else if(CHANNEL_UP)
        begin
          if(!data_in_frame_r && !RX_SOF_N_SLACK && !RX_SRC_RDY_N_SLACK && RX_EOF_N_SLACK)
            data_in_frame_r  <=      1'b1;
          else if(data_in_frame_r && !RX_SRC_RDY_N_SLACK && !RX_EOF_N_SLACK)
            data_in_frame_r  <=      1'b0;
        end

    //Register and decode the RX_D data with RX_REM bus
    always @ (posedge USER_CLK)
    begin 	      
      if((!RX_EOF_N_SLACK) && (!RX_SRC_RDY_N_SLACK))
      begin	
        case(RX_REM_1SLACK)
          2'd0 : RX_D_R <=   {RX_D_SLACK[0:7], 24'b0};
          2'd1 : RX_D_R <=   {RX_D_SLACK[0:15], 16'b0};
          2'd2 : RX_D_R <=   {RX_D_SLACK[0:23], 8'b0};
          2'd3 : RX_D_R <=   RX_D_SLACK;
          default : RX_D_R  <=   RX_D_SLACK; 		
	endcase 	
      end 
      else if(!RX_SRC_RDY_N_SLACK)
        RX_D_R          <=      RX_D_SLACK;
    end
    //Calculate the expected frame data
    always @ (posedge USER_CLK)
    begin
      if(reset_c)
        pdu_cmp_data_r <=  {2{16'hD5E6}};
      else if(CHANNEL_UP)
      begin
        if(data_valid_c && !RX_EOF_N_SLACK)
        begin		
          case(RX_REM_2SLACK)
            2'd0 : pdu_cmp_data_r <=   {data_lfsr_concat_w[0:7], 24'b0};
            2'd1 : pdu_cmp_data_r <=   {data_lfsr_concat_w[0:15], 16'b0};
            2'd2 : pdu_cmp_data_r <=   {data_lfsr_concat_w[0:23], 8'b0};
            2'd3 : pdu_cmp_data_r <=   data_lfsr_concat_w;
            default : pdu_cmp_data_r <=   data_lfsr_concat_w; 		
	  endcase 	
        end
        else if(data_valid_c)
          pdu_cmp_data_r <=   data_lfsr_concat_w; 		
        end
      end

    //generate expected RX_D using LFSR
    always @(posedge USER_CLK)
        if(reset_c)
        begin
            data_lfsr_r          <=      16'hD5E6;  //random seed value
        end
        else if(CHANNEL_UP)
        begin
          if(data_valid_c)
           data_lfsr_r          <=      {!{data_lfsr_r[3]^data_lfsr_r[12]^data_lfsr_r[14]^data_lfsr_r[15]},
                                data_lfsr_r[0:14]};
        end
        else 
        begin
           data_lfsr_r          <=      16'hD5E6;  //random seed value
        end 

    assign data_lfsr_concat_w = {DATA_WIDTH/16{data_lfsr_r}};

    //___________________________ Check incoming data for errors __________________________
    //An error is detected when LFSR generated RX data from the pdu_cmp_data_r register,
    //does not match valid data from the RX_D port
    assign  data_err_detected_c    = (data_valid_r && (RX_D_R != pdu_cmp_data_r));

    //We register the data_err_detected_c signal for use with the error counter logic
    always @(posedge USER_CLK)
      data_err_detected_r    <=      data_err_detected_c; 

    //Compare the incoming data with calculated expected data.
    //Increment the ERROR COUNTER if mismatch occurs.
    //Stop the ERROR COUNTER once it reaches its max value (i.e. 255)
    always @(posedge USER_CLK)
        if(CHANNEL_UP)
        begin
          if(&err_count_r)
            err_count_r       <=      err_count_r;
          else if(data_err_detected_r)
            err_count_r       <=      err_count_r + 1'b1;
        end
	else
        begin	       	
          err_count_r       <=      9'd0;
	end   

    //Here we connect the lower 8 bits of the count (the MSbit is used only to check when the counter reaches
    //max value) to the module output
    assign  ERR_COUNT =   err_count_r[1:8];

 endmodule           
