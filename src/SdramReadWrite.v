/*********************************************************************
                                                              
    SDRAM读写模块               
    描述: SDRAM读写
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.13  
    版权所有：一生一芯 
    Copyright (C) www.ysyx.org      

    NOTE: 1.这里有一些需要注意的地方，首先关于SDRAM芯片的定义格式
            <行数> x <位宽> x <Bank数>
          2.其次关于本设计的burst len ，当然是可以配置的但是不能超过
            一行的大小，因为每次读写也只能读写一行的内容，超过一行的内容
            也要进行precharge and line active
          3.其中每个bank他的存储方式也不相同格式为
            line × 单元数 × 单元存储位数 （bit）

                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "define.v"
`include "SyncFifo.v"
module SdramReadWrite #(
    parameter     SDRAMMHZ      =        100       ,
    parameter     SDRAMLINE     =        2048      ,
    parameter     SDRAMCLUM     =        256       ,
    parameter     SDRAMWIDTH    =        32        , // 和syncfifow相同 
    parameter     FIFODEPTH     =        16
) (
    input     wire                                                   Clk             ,
    input     wire                                                   Rest            ,

    //output    wire                                                   SdramAccept     ,

    input     wire                                                   SdramPchgReq    , //因为我使用的不是自动充电
    output    wire                                                   SdramPchgDone   ,

    input     wire                                                   SdramMRSReq     ,
    input     wire  [$clog2(SDRAMLINE)-1:0                         ] SdramMRSData    ,
    output    wire                                                   SdramMRSDone    ,

    input     wire                                                   SdramRowActReq  ,
    input     wire  [$clog2(SDRAMLINE)-1:0                         ] SdramWhichLine  ,
    input     wire  [1:0                                           ] SdramBankSelect ,
    output    wire                                                   SdramActDone    ,

    input     wire                                                   SdramReadReq    ,
    input     wire  [$clog2(SDRAMCLUM)-1:0                         ] SdramReadAddr   ,
    output    wire                                                   SdramReadDone   ,

    //output    wire                                                   RfifoToChipAble ,
    input     wire  [SDRAMWIDTH-1:0                                ] RfifoToChipData ,//从chip读入fifo

    input     wire                                                   ReadRfifoAble   ,//ctrl读fifo
    output    wire  [SDRAMWIDTH-1:0                                ] ReadRfifoData   ,
    output    wire                                                   RfifoEmpty      ,

    input     wire                                                   SdramWriteReq   ,
    input     wire  [$clog2(SDRAMCLUM)-1:0                         ] SdramWriteAddr  ,
    output    wire                                                   SdramWriteDone  ,

    //output    wire                                                   WfifoToChipAble ,
    output    wire  [(SDRAMWIDTH/8)-1 : 0                          ] WfifoToChipMk   ,//从fifo写入chip
    output    wire  [SDRAMWIDTH-1:0                                ] WfifoToChipData ,

    input     wire                                                   WriteWfifoAble  ,//从ctrl写入fifo
    input     wire  [SDRAMWIDTH+(SDRAMWIDTH/8)-1:0                 ] WriteWfifoData  ,
    output    wire                                                   WfifoFull       ,

    output    wire  [3:0                                           ] SdramToChipCmd  ,
    output    wire  [$clog2(SDRAMLINE)-1:0                         ] SdramToChipArg  ,
    output    wire  [1:0                                           ] SdramToChipBan    
);
    parameter NSPRESEC  =  $ceil(1000 / SDRAMMHZ) ;
    parameter CYCNURCD  =  $ceil(20   / NSPRESEC) ; 
    parameter CYCNUMRP  =  $ceil(20   / NSPRESEC) ; 
    parameter CYCNUMRD  =  2                      ; 

    reg  [6:0]  ModeRegTemp    ;
    //wire [15:0] BurstNumber    ;
    wire [15:0] BurstNumberSub ;
    wire        BurstType      ;
    wire [3:0]  CASLagcy       ;
    //wire [3:0]  CASLagcySub    ;
    // assign BurstNumber    = (ModeRegTemp[2:0] == 3'b000) ? 16'd1 : 
    //                         (ModeRegTemp[2:0] == 3'b001) ? 16'd2 : 
    //                         (ModeRegTemp[2:0] == 3'b010) ? 16'd4 : 
    //                         (ModeRegTemp[2:0] == 3'b011) ? 16'd8 :16'd0 ;
    //                         //(ModeRegTemp[2:0] == 3'b111) ? SDRAMCLUM :16'd0 ; //暂不支持fullpage
    assign BurstNumberSub = (ModeRegTemp[2:0] == 3'b000) ? 16'd0 : 
                            (ModeRegTemp[2:0] == 3'b001) ? 16'd1 : 
                            (ModeRegTemp[2:0] == 3'b010) ? 16'd3 : 
                            (ModeRegTemp[2:0] == 3'b011) ? 16'd7 :16'd0 ;
    assign BurstType      = ModeRegTemp[3]                                  ;
    assign CASLagcy       = (ModeRegTemp[6:4] == 3'b001) ? 4'd1 : 
                            (ModeRegTemp[6:4] == 3'b010) ? 4'd2 : 
                            (ModeRegTemp[6:4] == 3'b011) ? 4'd3 :4'd0       ;
    

    always @(posedge Clk) begin
        if(!Rest) begin
            ModeRegTemp <= 7'b0 ;
        end
        else if(SdramMRSReq) begin
            ModeRegTemp <= SdramMRSData[6:0] ;
        end
        else begin
            ModeRegTemp <= ModeRegTemp ;
        end
    end
    
    reg [7:0            ] WRState   ;
    reg [15:0]            WRCnt     ;

    always @(posedge Clk) begin
        if(!Rest) begin
            WRState   <= `SDRAMWRIDLE       ;
            WRCnt     <= 16'b0              ;
        end
        else begin
            case (WRState)
                `SDRAMWRIDLE : begin
                    WRCnt     <= 16'b0              ;
                    if(SdramMRSReq) begin //MRD需要两个周期
                        WRState   <= `SDRAMMRS      ;
                    end 
                    else if(SdramPchgReq) begin
                        WRState   <= `SDRAMPRECHG   ;
                    end
                    else if(SdramRowActReq) begin
                        WRState   <= `SDRAMROWACT   ;
                    end
                    else if(SdramReadReq)begin
                        WRState   <= `SDRAMRABLE    ;
                    end
                    else if(SdramWriteReq)begin
                        WRState   <= `SDRAMWABLE    ;
                    end
                    else begin
                        WRState   <= `SDRAMWRIDLE   ;
                    end
                end
                `SDRAMMRS : begin
                    if(WRCnt == CYCNUMRD-1) begin
                        WRState   <= `SDRAMWRIDLE    ;
                        WRCnt     <= 16'b0           ;  
                    end 
                    else begin
                        WRState   <= `SDRAMMRS     ;
                        WRCnt     <= WRCnt + 1      ;  
                    end
                end
                `SDRAMPRECHG : begin
                    if(WRCnt == CYCNUMRP-1) begin 
                        WRState   <= `SDRAMWRIDLE   ;
                        WRCnt     <= 16'b0          ;    
                    end 
                    else begin
                        WRState   <= `SDRAMPRECHG   ;
                        WRCnt     <= WRCnt + 1      ;  
                    end
                end
                `SDRAMROWACT : begin
                    if(WRCnt == CYCNURCD-1) begin 
                        WRState   <= `SDRAMWRIDLE   ;
                        WRCnt     <= 16'b0          ;    
                    end 
                    else begin
                        WRState   <= `SDRAMROWACT   ;
                        WRCnt     <= WRCnt + 1      ;  
                    end
                end
                `SDRAMRABLE : begin 
                    if(WRCnt == ({12'b0,CASLagcy} + BurstNumberSub)) begin
                        WRState   <= `SDRAMWRIDLE   ;
                        WRCnt     <= 16'd0          ;
                    end
                    else begin
                        WRState   <= `SDRAMRABLE    ;
                        WRCnt     <= WRCnt + 1      ;
                    end
                end
                `SDRAMWABLE : begin
                    if(WRCnt == (BurstNumberSub)) begin
                        WRState   <= `SDRAMWRIDLE   ;
                        WRCnt     <= 16'd0          ;
                    end
                    else begin
                        WRState   <= `SDRAMWABLE    ;
                        WRCnt     <= WRCnt + 1      ;
                    end
                end
                default: begin
                    
                end
            endcase
        end
    end    



    wire                  WfifoRAble ;
    wire [SDRAMWIDTH +(SDRAMWIDTH/8)-1:0] WfifoRData   ;

    assign SdramPchgDone    =  (WRState == `SDRAMPRECHG) && (WRCnt == CYCNUMRP-1) ;
    assign SdramActDone     =  (WRState == `SDRAMROWACT) && (WRCnt == CYCNURCD-1) ;
    //assign SdramAccept      =  (WRState == `SDRAMWRIDLE)                          ;

    assign WfifoRAble       = (WRState == `SDRAMWABLE) ;
    //assign WfifoToChipAble  = WfifoRAble               ;
    assign WfifoToChipData  = WfifoRAble ? WfifoRData[SDRAMWIDTH +(SDRAMWIDTH/8)-1:(SDRAMWIDTH/8)] : {SDRAMWIDTH{1'b0}} ;
    assign WfifoToChipMk    = WfifoRAble ? WfifoRData[(SDRAMWIDTH/8)-1:0] : {(SDRAMWIDTH/8){1'b0}};
    assign SdramWriteDone   = (WRState == `SDRAMWABLE) && (WRCnt == BurstNumberSub) ;

    wire                  RfifoWAble ;
    wire [SDRAMWIDTH-1:0] RfifoWData ;
    assign RfifoWAble       = (WRState == `SDRAMRABLE) && (WRCnt >= {12'b0,CASLagcy})    ;
    assign RfifoWData       = RfifoWAble ? RfifoToChipData : {SDRAMWIDTH{1'b0}}  ;
    //assign RfifoToChipAble  = (WRState == `SDRAMRABLE) ;
    assign SdramReadDone    = (WRState == `SDRAMRABLE) && (WRCnt == ({12'b0,CASLagcy} + BurstNumberSub)) ;
    
    assign SdramMRSDone     = (WRState == `SDRAMMRS)   && (WRCnt == 1) ;


    SyncFifo#(
        .WIDTH         ( SDRAMWIDTH    ),
        .DEPTH         ( FIFODEPTH     )
    )ReadSyncFifo(
        .Clk           ( Clk                  ),
        .Rest          ( Rest                 ),
        .WriteEn       ( RfifoWAble           ),
        .WriteData     ( RfifoWData           ),
        .FifoFullSign  (                      ),
        .FifoEmptySign ( RfifoEmpty           ),
        .ReadEn        ( ReadRfifoAble        ),
        .ReadData      ( ReadRfifoData        )
    );

    SyncFifo#(
        .WIDTH         ( SDRAMWIDTH + (SDRAMWIDTH/8) ),
        .DEPTH         ( FIFODEPTH                   )
    )WriteSyncFifo(
        .Clk           ( Clk                   ),
        .Rest          ( Rest                  ),
        .WriteEn       ( WriteWfifoAble        ),
        .WriteData     ( WriteWfifoData        ),
        .FifoFullSign  ( WfifoFull             ),
        .FifoEmptySign (                       ),//因为fifo一定是完成burst数据预存才会开始，所以不会出现empty
        .ReadEn        ( WfifoRAble            ),//fast read 
        .ReadData      ( WfifoRData            )
    );

    assign SdramToChipCmd = (WRState == `SDRAMWABLE) && (WRCnt == 0) ? `WRITEC     :
                            (WRState == `SDRAMRABLE) && (WRCnt == 0) ? `READC      :
                            (WRState == `SDRAMMRS)   && (WRCnt == 0) ? `MODEREGSET : 
                            (WRState == `SDRAMROWACT)&& (WRCnt == 0) ? `ROWACTIVE  :
                            (WRState == `SDRAMPRECHG)&& (WRCnt == 0) ? `PRECHAGE   :`NOPC ;
    assign SdramToChipArg = (WRState == `SDRAMWABLE) && (WRCnt == 0) ? {{$clog2(SDRAMLINE)-$clog2(SDRAMCLUM){1'b0}},SdramWriteAddr} :
                            (WRState == `SDRAMRABLE) && (WRCnt == 0) ? {{$clog2(SDRAMLINE)-$clog2(SDRAMCLUM){1'b0}},SdramReadAddr}  :
                            (WRState == `SDRAMMRS)   && (WRCnt == 0) ? SdramMRSData   :
                            (WRState == `SDRAMROWACT)&& (WRCnt == 0) ? SdramWhichLine :
                            (WRState == `SDRAMPRECHG)&& (WRCnt == 0) ? {{$clog2(SDRAMLINE)-11{1'b0}},1'b1,10'b0} : {$clog2(SDRAMLINE){1'b0}} ;

    assign SdramToChipBan = (WRState == `SDRAMROWACT)  && (WRCnt == 0) ? SdramBankSelect  :  2'b00 ;
    
endmodule
