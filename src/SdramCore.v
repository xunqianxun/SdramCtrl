/*********************************************************************
                                                              
    SDRAM Core               
    描述: SDRAN Core
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.12  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "define.v"
module SdramCore #(
    parameter     SDRAMMHZ      =        100       ,
    parameter     SDRAMLINE     =        2048      ,
    parameter     SDRAMCLUM     =        256       ,
    parameter     SDRAMWIDTH    =        32        , // 和syncfifow相同 
    parameter     FIFODEPTH     =        16
) (

    input     wire                                                Clk             ,
    input     wire                                                Rest            ,
 
    input     wire                                                ReadAble        ,
    input     wire                                                WriteAble       ,
    output    wire                                                AcceptDone      ,
    input     wire                                                MRSAble         ,
    input     wire  [$clog2(SDRAMLINE)-1:0                      ] MRSData         ,
    input     wire  [$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)+2-1:0] RorWAddr        , // bank + line + clum 
    input     wire  [$clog2(SDRAMCLUM-1)-1:0                      ] RorWNumber      ,
    output    wire                                                RorWFinish      ,
    
    input     wire                                                CtrlCanAccept   ,
    output    wire                                                OutDataValid    ,
    output    wire  [SDRAMWIDTH-1:0                             ] ReadData        ,

    output    wire                                                WriteCanAccept  ,
    input     wire                                                InDataValid     ,
    input     wire  [SDRAMWIDTH + (SDRAMWIDTH/8) -1:0           ] WriteData       , //写进来的包含者每一次传输的数据和他的掩码 data + mask 


    input     wire  [SDRAMWIDTH-1 : 0                           ] ChipDin         ,
    output    wire  [SDRAMWIDTH-1 : 0                           ] ChipDout        ,
    output    wire  [$clog2(SDRAMLINE)-1:0                      ] ChipAddr        ,
    output    wire  [1 : 0                                      ] ChipBank        ,
    output    wire                                                ChipClk         ,
    output    wire                                                ChipCke         , 
    output    wire                                                ChipCs_n        ,
    output    wire                                                ChipRas_n       ,
    output    wire                                                ChipCas_n       ,
    output    wire                                                ChipWe_n        ,
    output    wire  [(SDRAMWIDTH/8)-1:0                         ] ChipDqm
);

wire        ReadDataDone  ;
wire        WriteDataDone ;
wire        ArefRequest   ;

wire        SdramInitFinsh ;
wire        PreChageFinish  ;
wire        ModeRegSetFinsh ;
wire        RowActiveFinish ;
wire        AutoRefFinish   ;


reg [7:0                                        ] CoreState   ;
reg [$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)+2-1:0] AddrTemp    ;
reg [$clog2(SDRAMCLUM)-1 : 0                    ] NumberTemp  ;
reg [7:0                                        ] CoreCnt     ;
reg                                               CtrlInDone  ;
reg                                               ReadFlow    ;
reg                                               WriteFlow   ;
reg [7:0                                        ] AheadState  ;
reg [$clog2(SDRAMLINE)-1:0                      ] MRSDataTemp ;
reg                                               MRSAbleTemp ;
reg                                               RorWDone    ;


wire [3:0                                       ] BurstNumber ;
assign BurstNumber = (MRSDataTemp[2:0] == 3'b000) ? 4'd1 : 
                     (MRSDataTemp[2:0] == 3'b001) ? 4'd2 : 
                     (MRSDataTemp[2:0] == 3'b010) ? 4'd4 : 
                     (MRSDataTemp[2:0] == 3'b011) ? 4'd8 : 4'd0 ; 

wire                   RfifoEmptySign ;//fast empty

always @(posedge Clk) begin
    if(!Rest)begin
        CoreState   <= `SCOREINIT ;
        AddrTemp    <= {$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+2{1'b0}};
        NumberTemp  <= {$clog2(SDRAMCLUM){1'b0}};
        CoreCnt     <= 8'd0  ;
        CtrlInDone  <= `FALSE;
        ReadFlow    <= `FALSE;
        WriteFlow   <= `FALSE;
        AheadState  <= `SCOREINIT;
        MRSDataTemp <= {$clog2(SDRAMLINE){1'b0}};
        MRSAbleTemp <= `FALSE;
        RorWDone    <= `FALSE;
    end
    else begin
        case (CoreState)
            `SCOREINIT : begin
                AddrTemp    <= {$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+2{1'b0}};
                NumberTemp  <= {$clog2(SDRAMCLUM){1'b0}};
                CoreCnt     <= 8'd0  ;
                CtrlInDone  <= `FALSE;
                ReadFlow    <= `FALSE;
                WriteFlow   <= `FALSE;
                AheadState  <= `SCOREINIT;
                MRSDataTemp <= {$clog2(SDRAMLINE){1'b0}};
                MRSAbleTemp <= `FALSE;
                RorWDone    <= `FALSE;
                if(SdramInitFinsh) begin 
                    CoreState <= `SCOREIDLE ;
                end 
                else begin
                    CoreState <= `SCOREINIT ;
                end
            end
            `SCOREIDLE : begin
                if(ArefRequest)begin
                    CoreState   <= `SCOREAREF  ;
                    AddrTemp    <= {$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+2{1'b0}};
                    NumberTemp  <= {$clog2(SDRAMCLUM){1'b0}};
                    CoreCnt     <= 8'd0        ;
                    CtrlInDone  <= `FALSE      ;
                    ReadFlow    <= `FALSE      ;
                    WriteFlow   <= `FALSE      ;
                    AheadState  <= `SCOREIDLE  ;
                    MRSDataTemp <= {$clog2(SDRAMLINE){1'b0}};
                    MRSAbleTemp <= `FALSE      ;
                    RorWDone    <= `FALSE      ;
                end
                else if(ReadAble)begin
                    CoreState   <= `SCOREPCHGE ;
                    AddrTemp    <= RorWAddr    ;
                    NumberTemp  <= RorWNumber  ;
                    CoreCnt     <= 8'd0        ;
                    CtrlInDone  <= `TURE       ;
                    ReadFlow    <= `TURE       ;
                    WriteFlow   <= `FALSE      ;
                    AheadState  <= `SCOREIDLE  ;
                    MRSDataTemp <= MRSData     ;
                    MRSAbleTemp <= MRSAble     ;
                    RorWDone    <= `FALSE      ;
                end
                else if(WriteAble)begin
                    CoreState   <= `SCOREPCHGE ;
                    AddrTemp    <= RorWAddr    ;
                    NumberTemp  <= RorWNumber  ;
                    CoreCnt     <= 8'd0        ;
                    CtrlInDone  <= `TURE       ;
                    ReadFlow    <= `FALSE      ;
                    WriteFlow   <= `TURE       ;
                    AheadState  <= `SCOREIDLE  ;
                    MRSDataTemp <= MRSData     ;
                    MRSAbleTemp <= MRSAble     ;
                    RorWDone    <= `FALSE      ;
                end
                else begin
                    CoreState   <= `SCOREIDLE  ;
                    AddrTemp    <= {$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+2{1'b0}};
                    NumberTemp  <= {$clog2(SDRAMCLUM){1'b0}};
                    CoreCnt     <= 8'd0        ;
                    CtrlInDone  <= `FALSE      ;
                    ReadFlow    <= `FALSE      ;
                    WriteFlow   <= `FALSE      ;
                    AheadState  <= AheadState  ;
                    MRSDataTemp <= {$clog2(SDRAMLINE){1'b0}};
                    MRSAbleTemp <= `FALSE      ;
                    RorWDone    <= `FALSE      ;
                end
            end
            `SCOREPCHGE : begin
                AddrTemp      <= AddrTemp    ;
                NumberTemp    <= NumberTemp  ;
                CoreCnt       <= CoreCnt     ;
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                RorWDone      <= `FALSE      ;
                if(PreChageFinish)begin
                    if(ArefRequest)begin
                        CoreState   <= `SCOREAREF  ;
                        AheadState  <= `SCOREPCHGE ;
                    end
                    else if(MRSAbleTemp) begin
                        CoreState   <= `SCOREMRS   ;
                        AheadState  <= `SCOREPCHGE ;
                    end
                    else begin
                        CoreState   <= `SCOREROWACT;
                        AheadState  <= `SCOREPCHGE ;
                    end 
                end
                else begin
                    CoreState <= `SCOREPCHGE ;
                    AheadState<= AheadState  ;
                end
            end
            `SCOREMRS : begin
                AddrTemp      <= AddrTemp    ;
                NumberTemp    <= NumberTemp  ;
                CoreCnt       <= CoreCnt     ;
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                RorWDone      <= `FALSE      ;
                if(ModeRegSetFinsh)begin
                    if(ArefRequest)begin
                        CoreState    <= `SCOREAREF ;
                        AheadState  <= `SCOREMRS  ;
                    end
                    else begin 
                        CoreState   <= `SCOREROWACT;
                        AheadState  <= `SCOREMRS   ;
                    end 
                end
                else begin
                    CoreState <= `SCOREMRS ;
                    AheadState<= AheadState;
                end
            end
            `SCOREROWACT : begin
                AddrTemp      <= AddrTemp    ;
                NumberTemp    <= NumberTemp  ;
                CoreCnt       <= CoreCnt     ;
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                RorWDone      <= `FALSE      ;
                if(RowActiveFinish)begin
                    if(ArefRequest)begin
                        CoreState    <= `SCOREAREF   ;
                        AheadState  <= `SCOREROWACT ;
                    end
                    else begin 
                        CoreState   <= ReadFlow ? `SCOREREAD  :
                                       WriteFlow? `SCOREWRITE : `SCOREIDLE ;
                        AheadState  <= `SCOREROWACT ;
                    end 
                end
                else begin
                    CoreState <= `SCOREROWACT ;
                    AheadState<= AheadState   ;
                end
            end
            `SCOREREAD : begin
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                RorWDone      <= `FALSE      ;
                if(ReadDataDone) begin 
                    if(ArefRequest)begin
                        CoreState  <= `SCOREAREF  ;
                        AheadState <= `SCOREREAD  ;
                        AddrTemp   <= (NumberTemp == 0) ? AddrTemp   : AddrTemp   + {{$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)-2{1'b0}}, BurstNumber}; 
                        NumberTemp <= (NumberTemp == 0) ? NumberTemp : NumberTemp - {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                        CoreCnt    <= (NumberTemp == 0) ? CoreCnt    : CoreCnt    + {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                    end
                    else if(NumberTemp == 0) begin
                        CoreState  <= `OPTFINISH   ;
                        AheadState <= `SCOREREAD   ;
                        AddrTemp   <= AddrTemp     ; 
                        NumberTemp <= NumberTemp   ;
                        CoreCnt    <= CoreCnt      ;
                    end
                    else begin 
                        CoreState  <= `SCOREREAD ;
                        AheadState <= AheadState ;
                        AddrTemp   <= AddrTemp   + {{$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)-2{1'b0}}, BurstNumber}; 
                        NumberTemp <= NumberTemp - {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                        CoreCnt    <= CoreCnt    + {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                    end 
                end
                else begin
                    AddrTemp   <= AddrTemp   ;
                    NumberTemp <= NumberTemp ;
                    CoreCnt    <= CoreCnt    ;
                    CoreState  <= `SCOREREAD ;
                    AheadState <= AheadState ;
                end
            end
            `SCOREWRITE : begin //因为每次读写的开始时候都会进行预充电所以在每次传输结束的时候就不进行预充电了
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                if(WriteDataDone) begin 
                    if(ArefRequest)begin
                        CoreState  <= `SCOREAREF  ;
                        AheadState <= `SCOREWRITE ;
                        AddrTemp   <= (NumberTemp == 0) ? AddrTemp   : AddrTemp   + {{$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)-2{1'b0}}, BurstNumber}; 
                        NumberTemp <= (NumberTemp == 0) ? NumberTemp : NumberTemp - {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                        CoreCnt    <= (NumberTemp == 0) ? CoreCnt    : CoreCnt    + {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber}; //这里的都是按照SDRAM的WIDTH来决定的
                        RorWDone   <= `FALSE      ;
                    end
                    else if(NumberTemp == 1) begin
                        CoreState  <= `SCOREIDLE   ;
                        AheadState <= `SCOREWRITE  ;
                        AddrTemp   <= AddrTemp     ;
                        NumberTemp <= NumberTemp   ;
                        CoreCnt    <= CoreCnt      ;
                        RorWDone   <= `TURE        ;
                    end
                    else begin 
                        CoreState  <= `SCOREWRITE ;
                        AheadState <= AheadState  ;
                        AddrTemp   <= AddrTemp   + {{$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)-2{1'b0}}, BurstNumber}; 
                        NumberTemp <= NumberTemp - {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                        CoreCnt    <= CoreCnt    + {{$clog2(SDRAMCLUM)-4{1'b0}}, BurstNumber};
                        RorWDone   <= `FALSE      ;
                    end 
                end
                else begin
                    AddrTemp   <= AddrTemp    ;
                    NumberTemp <= NumberTemp  ;
                    CoreCnt    <= CoreCnt     ;
                    CoreState  <= `SCOREWRITE ;
                    AheadState <= AheadState  ;
                    RorWDone   <= `FALSE      ;
                end
            end
            `OPTFINISH : begin
                AddrTemp      <= AddrTemp    ;
                NumberTemp    <= NumberTemp  ;
                CoreCnt       <= CoreCnt     ;
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                if(RfifoEmptySign)begin
                    if(ArefRequest)begin
                        CoreState  <= `SCOREAREF  ;
                        AheadState <= `OPTFINISH  ;
                        RorWDone   <= `FALSE      ;
                    end 
                    else begin
                        CoreState  <= `SCOREIDLE  ;
                        AheadState <= `OPTFINISH  ;
                        RorWDone   <= `TURE       ;
                    end 
                end
                else begin
                    CoreState  <= `OPTFINISH  ;
                    AheadState <= AheadState  ;
                    RorWDone   <= `FALSE      ;
                end
            end
            `SCOREAREF : begin
                AddrTemp      <= AddrTemp    ;
                NumberTemp    <= NumberTemp  ;
                CoreCnt       <= CoreCnt     ;
                CtrlInDone    <= `FALSE      ;
                ReadFlow      <= ReadFlow    ;
                WriteFlow     <= WriteFlow   ;
                MRSDataTemp   <= MRSDataTemp ;
                MRSAbleTemp   <= MRSAbleTemp ;
                RorWDone      <= `FALSE      ;
                if(AutoRefFinish) begin
                    if(AheadState == `SCOREIDLE) begin 
                        CoreState <= `SCOREIDLE;
                    end 
                    else if(AheadState == `SCOREPCHGE) begin
                        if(MRSAbleTemp) begin
                            CoreState <= `SCOREMRS ;
                        end
                        else begin
                            CoreState <= `SCOREROWACT ;
                        end
                    end
                    else if(AheadState == `SCOREMRS) begin
                        CoreState <= `SCOREROWACT;
                    end 
                    else if(AheadState == `SCOREROWACT) begin
                        CoreState <= ReadFlow ? `SCOREREAD  :
                                     WriteFlow? `SCOREWRITE : `SCOREIDLE ;
                    end
                    else if(AheadState == `SCOREREAD) begin
                        if(NumberTemp == 0) begin
                            CoreState <= `OPTFINISH ;
                        end
                        else begin
                            AheadState <= `SCOREREAD;
                        end
                    end
                    else if(AheadState == `SCOREWRITE) begin
                        if(NumberTemp == 0) begin
                            CoreState <= `SCOREIDLE ;
                        end
                        else begin
                            AheadState <= `SCOREWRITE;
                        end
                    end
                    else begin
                        CoreState <= `OPTFINISH ;
                    end
                    AheadState <= `SCOREAREF ;
                end
                else begin
                    CoreState  <= `SCOREAREF  ;
                    AheadState <= AheadState  ;
                end
            end
            default: begin
                CoreState   <= `SCOREINIT ;
                AddrTemp    <= {$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+2{1'b0}};
                NumberTemp  <= {$clog2(SDRAMCLUM){1'b0}};
                CoreCnt     <= 8'd0  ;
                CtrlInDone  <= `FALSE;
                ReadFlow    <= `FALSE;
                WriteFlow   <= `FALSE;
                AheadState  <= `SCOREINIT;
                MRSDataTemp <= {$clog2(SDRAMLINE){1'b0}};
                MRSAbleTemp <= `FALSE;
                RorWDone    <= `FALSE      ;
            end
        endcase
    end
end

reg [7:0] ReadCnt ; //用来判定可否继续burst
reg [7:0] WriteCnt ;
assign AcceptDone = CtrlInDone ;
assign RorWFinish = RorWDone   ;

wire [$clog2(SDRAMLINE)-1:0] InitModeData   ;
wire [$clog2(SDRAMLINE)-1:0] ArefModeData   ;
wire [$clog2(SDRAMLINE)-1:0] SdramModeData  ;
wire [3:0                  ] InitCMDData    ;
wire [3:0                  ] ArefCMDDate    ;
wire [3:0                  ] SdramCMDData   ;
wire [1:0                  ] SdramBankData  ;
wire [SDRAMWIDTH-1 : 0     ] SdramDataIn    ;
wire [(SDRAMWIDTH/8)-1 : 0 ] SdramMaskIn    ;


wire                         InInitState    ;
wire                         InArefState    ;
wire                         InIdleState    ;
wire                         InRWPchgeState ;
wire                         InRWRowActState;
wire                         InRWMRSState   ;
wire                         InRWReadState  ;
wire                         InRWWriteState ;
wire                         InRWOptFinState;
assign InInitState    = (CoreState == `SCOREINIT)                                              ? `TURE : `FALSE ;
assign InArefState    = (CoreState == `SCOREAREF)                                              ? `TURE : `FALSE ;
assign InIdleState    = (CoreState == `SCOREIDLE)                                              ? `TURE : `FALSE ;
assign InRWPchgeState = (CoreState == `SCOREPCHGE)                                             ? `TURE : `FALSE ;
assign InRWRowActState= (CoreState == `SCOREROWACT)                                            ? `TURE : `FALSE ;
assign InRWMRSState   = (CoreState == `SCOREMRS)                                               ? `TURE : `FALSE ;
assign InRWReadState  = ((CoreState == `SCOREREAD)  && ((CoreCnt  - ReadCnt) >= {4'b0,BurstNumber} )) ? `TURE : `FALSE ;
assign InRWWriteState = ((CoreState == `SCOREWRITE) && ((WriteCnt - CoreCnt) >= {4'b0,BurstNumber} )) ? `TURE : `FALSE ;
assign InRWOptFinState= (CoreState == `OPTFINISH)                                              ? `TURE : `FALSE ;

wire [$clog2(SDRAMLINE)-1:0] SdramLineOut  ;
assign SdramLineOut   = InRWRowActState  ? AddrTemp[$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)-1 : $clog2(SDRAMCLUM)] : {$clog2(SDRAMLINE){1'b0}} ;
wire [1:0                  ] SdramBankOut  ;
assign SdramBankOut   = InRWRowActState  ? AddrTemp[$clog2(SDRAMLINE)+$clog2(SDRAMCLUM)+1 : $clog2(SDRAMLINE)+$clog2(SDRAMCLUM)] : 2'b0    ;
wire [$clog2(SDRAMLINE)-1:0] SdramMROut    ;
assign SdramMROut     = InRWMRSState     ? MRSDataTemp : {$clog2(SDRAMLINE){1'b0}};
wire [$clog2(SDRAMCLUM)-1:0] SdramClumOut  ;
assign SdramClumOut   = (InRWReadState || InRWWriteState) ? AddrTemp[$clog2(SDRAMCLUM)-1 : 0] : {$clog2(SDRAMCLUM){1'b0}} ;



assign ChipDout   = InInitState      ? {SDRAMWIDTH{1'b0}}     :
                    InArefState      ? {SDRAMWIDTH{1'b0}}     :
                    InIdleState      ? {SDRAMWIDTH{1'b0}}     :
                    InRWPchgeState   ? {SDRAMWIDTH{1'b0}}     :
                    InRWRowActState  ? {SDRAMWIDTH{1'b0}}     : 
                    InRWMRSState     ? {SDRAMWIDTH{1'b0}}     :
                    InRWReadState    ? {SDRAMWIDTH{1'b0}}     :
                    InRWWriteState   ? SdramDataIn            :
                    InRWOptFinState  ? {SDRAMWIDTH{1'b0}}     : {SDRAMWIDTH{1'b0}}       ;
assign ChipAddr   = InInitState      ? InitModeData           :
                    InArefState      ? ArefModeData           :
                    InIdleState      ? {$clog2(SDRAMLINE){1'b0}}:
                    InRWPchgeState   ? SdramModeData          : 
                    InRWRowActState  ? SdramModeData          : 
                    InRWMRSState     ? SdramModeData          :
                    InRWReadState    ? SdramModeData          :
                    InRWWriteState   ? SdramModeData          :
                    InRWOptFinState  ? {$clog2(SDRAMLINE){1'b0}}: {$clog2(SDRAMLINE){1'b0}};
assign ChipBank   = InInitState      ? 2'b0                   :
                    InArefState      ? 2'b0                   :
                    InIdleState      ? 2'b0                   :
                    InRWPchgeState   ? 2'b0                   : 
                    InRWRowActState  ? SdramBankData          :
                    InRWMRSState     ? 2'b0                   :
                    InRWReadState    ? 2'b0                   :
                    InRWWriteState   ? 2'b0                   :
                    InRWOptFinState  ? 2'b0                   : 2'b0                     ;
assign ChipClk    = ~Clk ;//Sdram要在数据稳定时采集数据。
assign ChipCke    = `TURE; //内部时钟使能，关闭则为低功耗，这里恒为真。
assign {ChipCs_n ,
        ChipRas_n,
        ChipCas_n,
        ChipWe_n} = InInitState     ? InitCMDData            :
                    InArefState     ? ArefCMDDate            :
                    InIdleState     ? `NOPC                  :
                    InRWPchgeState  ? SdramCMDData           :
                    InRWRowActState ? SdramCMDData           :
                    InRWMRSState    ? SdramCMDData           :
                    InRWReadState   ? SdramCMDData           :
                    InRWWriteState  ? SdramCMDData           :
                    InRWOptFinState ? `NOPC                  : `NOPC                     ;
assign ChipDqm    = InInitState     ? {(SDRAMWIDTH/8){1'b0}} :
                    InArefState     ? {(SDRAMWIDTH/8){1'b0}} :
                    InIdleState     ? {(SDRAMWIDTH/8){1'b0}} :
                    InRWPchgeState  ? {(SDRAMWIDTH/8){1'b0}} :
                    InRWRowActState ? {(SDRAMWIDTH/8){1'b0}} :
                    InRWMRSState    ? {(SDRAMWIDTH/8){1'b0}} :
                    InRWReadState   ? {(SDRAMWIDTH/8){1'b0}} :
                    InRWWriteState  ? SdramMaskIn            :
                    InRWOptFinState ? {(SDRAMWIDTH/8){1'b0}} : {(SDRAMWIDTH/8){1'b0}}    ;

wire [SDRAMWIDTH-1:0]  ReadFifoData   ;
reg                    RfifoEmptyReg  ; 
always @(posedge Clk) begin
    if(!Rest) begin
        RfifoEmptyReg <= 1'b0 ;
    end
    else begin
        RfifoEmptyReg <= RfifoEmptySign ;
    end
end

always @(posedge Clk) begin
    if(!Rest) begin
        ReadCnt <= 8'b0 ;
    end
    else if(CoreState == `SCOREIDLE) begin
        ReadCnt <= 8'b0 ;
    end
    else if(CtrlCanAccept && ~RfifoEmptyReg)begin
        ReadCnt <= ReadCnt + 1 ;
    end
    else begin
        ReadCnt <= ReadCnt ;
    end
end

assign OutDataValid   = ~RfifoEmptyReg && ~(CoreState == `SCOREINIT) ;
assign ReadData       =  ReadFifoData  ;


wire                  WfifoFullSign ;//fast full
assign WriteCanAccept = ~WfifoFullSign  && ~(CoreState == `SCOREINIT) ;
always @(posedge Clk) begin
    if(!Rest) begin
        WriteCnt <= 8'd0 ;
    end
    else if(CoreState == `SCOREIDLE) begin
        WriteCnt <= 8'd0 ; 
    end
    else if(InDataValid && ~WfifoFullSign)begin
        WriteCnt <= WriteCnt + 1 ;
    end
    else begin
        WriteCnt <= WriteCnt ;
    end
end


SdramAref#(
    .SDRAMMHZ   ( SDRAMMHZ     ),
    .SDRAMLINE  ( SDRAMLINE    )
)u_SdramAref(
    .Clk        ( Clk          ),
    .Rest       ( Rest         ),
    .SdramGetS  ( InArefState  ),
    .ArefReq    ( ArefRequest  ),
    .ArefCmd    ( ArefCMDDate  ),
    .ArefMode   ( ArefModeData ),
    .ArefDone   ( AutoRefFinish)
);

SdramInit#(
    .SDRAMMHZ       ( SDRAMMHZ        ),
    .SDRAMLINE      ( SDRAMLINE       )
)u_SdramInit(
    .Clk            ( Clk             ),
    .Rest           ( Rest            ),
    .ReInit         ( 1'b0            ),
    .SdramCmd       ( InitCMDData     ),
    .SdramMode      ( InitModeData    ),
    .SdramInitDone  ( SdramInitFinsh  )
);

SdramReadWrite#(
    .SDRAMMHZ         ( SDRAMMHZ         ),
    .SDRAMLINE        ( SDRAMLINE        ),
    .SDRAMCLUM        ( SDRAMCLUM        ),
    .SDRAMWIDTH       ( SDRAMWIDTH       ),
    .FIFODEPTH        ( FIFODEPTH        )
)u_SdramReadWrite(
    .Clk              ( Clk              ),
    .Rest             ( Rest             ),
    .SdramPchgReq     ( InRWPchgeState   ),
    .SdramPchgDone    ( PreChageFinish   ),
    .SdramMRSReq      ( InRWMRSState     ),
    .SdramMRSData     ( SdramMROut       ),
    .SdramMRSDone     ( ModeRegSetFinsh  ),
    .SdramRowActReq   ( InRWRowActState  ),
    .SdramWhichLine   ( SdramLineOut     ),
    .SdramBankSelect  ( SdramBankOut     ),
    .SdramActDone     ( RowActiveFinish  ),
    .SdramReadReq     ( InRWReadState    ),
    .SdramReadAddr    ( SdramClumOut     ),
    .SdramReadDone    ( ReadDataDone     ),
    .RfifoToChipData  ( ChipDin          ),
    .ReadRfifoAble    ( CtrlCanAccept    ),
    .ReadRfifoData    ( ReadFifoData     ),
    .RfifoEmpty       ( RfifoEmptySign   ),
    .SdramWriteReq    ( InRWWriteState   ),
    .SdramWriteAddr   ( SdramClumOut     ),
    .SdramWriteDone   ( WriteDataDone    ),
    .WfifoToChipMk    ( SdramMaskIn      ),
    .WfifoToChipData  ( SdramDataIn      ),
    .WriteWfifoAble   ( InDataValid      ),
    .WriteWfifoData   ( WriteData        ),
    .WfifoFull        ( WfifoFullSign    ),
    .SdramToChipCmd   ( SdramCMDData     ),
    .SdramToChipArg   ( SdramModeData    ),
    .SdramToChipBan   ( SdramBankData    )
);


    
endmodule
