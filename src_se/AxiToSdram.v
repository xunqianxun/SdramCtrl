/*********************************************************************
                                                              
    AXI转SDRAM               
    描述: 输入AXI从机接口输出SDRAM控制器接口   
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.8  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       

    MT48LC32M16A2 – 8 Meg x 16 x 4 banks
    https://www.mouser.com/datasheet/2/12/512M-SDRAM-MT48LC32M16A2P-20140714-1288428.pdf?srsltid=AfmBOoqiOpHLDtx0-2NteJB3OdBsoWmHyavi2HSVatm6SaGD2t2qoN8_
                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "NsyncFifo.v"
`include "define.v"
module AxiToSdram (
    input       wire                                                AxiClk         ,
    input       wire                                                AxiRest        ,
    input       wire                                                SdramClk       ,
    input       wire                                                SdramRest      ,

    input       wire  [`AXIID                                     ] AwidSlave      ,
    input       wire  [`AXIADDRW                                  ] AwaddrSlave    , //sdram的地址范围导致会有一部分no used
    input       wire  [`AXILEN                                    ] AwlenSlave     ,
    input       wire  [`AXISIZE                                   ] AwsizeSlave    ,
    input       wire  [`AXIBURST                                  ] AwburstSlave   , //只支持INCR
    input       wire                                                AwlockSlave    , //暂时不支持原子访问，如果需要后续在添加，或者直接用户软实现
    input       wire  [`AXICACHE                                  ] AwcacheSlave   , //主要用于缓存和一致性，这里不会使用，目前所支持的状态为x01x，即nubuffer and canmodify
    input       wire  [`AXIPORT                                   ] AwportSlave    , //由于sdram并不需要知道安全类型，所以忽略该信号   
    input       wire                                                AwvalidSlave   ,
    output      wire                                                AwreadySlave   ,

    input       wire  [`AXIID                                     ] WidSlave       ,
    input       wire  [`AXIWIDTH                                  ] WdataSlave     ,
    input       wire  [`AXISTRB                                   ] WstrbSlave     ,
    input       wire                                                WlastSlave     ,
    input       wire                                                WvalidSlave    ,
    output      wire                                                WreadySlave    ,

    output      wire  [`AXIID                                     ] BidSlave       , //sdram写通道如果发生写错误就会直接stop，所以可以直接回传okey信息
    output      wire  [`AXIRESP                                   ] BrespSlave     ,
    output      wire                                                BvalidSlave    ,
    input       wire                                                BreadySlave    ,

    input       wire  [`AXIID                                     ] AridSlave      ,
    input       wire  [`AXIADDRW                                  ] AraddrSlave    ,
    input       wire  [`AXILEN                                    ] ArlenSlave     ,
    input       wire  [`AXISIZE                                   ] ArsizeSlave    ,
    input       wire  [`AXIBURST                                  ] ArBurstSlave   ,
    input       wire                                                ArlockSlave    ,
    input       wire  [`AXICACHE                                  ] ArcacheSlave   ,
    input       wire  [`AXIPORT                                   ] ArportSlave    ,
    input       wire                                                ArvalidSlave   ,
    output      wire                                                ArreadySlave   ,

    output      wire  [`AXIID                                     ] RidSlave       ,
    output      wire  [`AXIWIDTH                                  ] RdataSlave     ,
    output      wire  [`AXIRESP                                   ] RrespSlave     ,
    output      wire                                                RlastSlave     ,
    output      wire                                                RvalidSlave    ,
    input       wire                                                RreadySlave    ,

    inout             [15:0                                       ] ChipDq         ,
    output      wire  [12:0                                       ] ChipAddr       ,
    output      wire  [1 :0                                       ] ChipBank       ,
    output      wire                                                ChipClk        ,
    output      wire                                                ChipCke        , 
    output      wire                                                ChipCs_n       ,
    output      wire                                                ChipRas_n      ,
    output      wire                                                ChipCas_n      ,
    output      wire                                                ChipWe_n       ,
    output      wire  [1 :0                                       ] ChipDqm
);
    /***********************Axi依赖原则*************************\
    对于读通道： 
    （1）设备在ARVALID出现的时候在给出ARREADY信号。
    （2）但是设备必须等待ARVALID和ARREADY信号都有效才能给出RVALID信号，开始数据传输。
    对于写通道：
    （1）主机必须不能够等待设备先给出AWREADY或WREADY信号信号后再给出信号AWVALID或WVLAID。
    （2）设备可以等待信号AWVALID或WVALID信号有效或者两个都有效之后再给出AWREADY信号。
    （3）设备可以等待AWVALID或WVALID信号有效或者两个信号都有效之后再给出WREADY信号。
    对于总线的设计：
    （1）由于sdram只能在同一时间内读或者写，那么在设计中我会逐步相应有读时相应读没读响应写
    \***********************Axi依赖原则*************************/


    parameter SDRAMMHZ  =        100              ;
    parameter NSPRESEC  =  $ceil(1000 / SDRAMMHZ) ;
    parameter CYCNURCD  =  $ceil(20   / NSPRESEC) ; 
    parameter CYCNUMRP  =  $ceil(20   / NSPRESEC) ; 
    parameter CYCNUMRD  =  2                      ; 


    reg [31:0]AxiAddr    ;
    reg [7:0] AxiState   ;
    reg [7:0] CntBurst   ;
    reg [7:0] AxiLen     ;
    reg [2:0] AxiSize    ;
    reg [31:0]AxiInData  ;
    reg [3:0] AxiMask    ;
    reg [3:0] AxiId      ;
    // reg       IssueRead  ;
    // reg       IssueWrite ;


    wire       DataSuccess;
    wire       UnBazyWrite;

    wire [3:0] NumberData ;
    assign NumberData = (AxiSize == 3'b000) ? 4'b0001 :
                        (AxiSize == 3'b001) ? 4'b0010 :
                        (AxiSize == 3'b010) ? 4'b0100 : 4'b0000 ;

    always @(posedge AxiClk) begin
        if(!AxiRest) begin
            AxiState <= `AXIIDLE       ;
            CntBurst <= 8'b0           ;
            AxiLen   <= 8'b0           ;
            AxiSize  <= 3'b0           ;
            AxiAddr  <= 32'b0          ;
            AxiInData<= 32'b0          ;
            AxiMask  <= 4'b0           ;
            AxiId    <= 4'b0           ;
            // IssueRead<= 1'b0           ;
            // IssueWrite<= 1'b0          ;
        end
        else begin
            case (AxiState)
                `AXIIDLE : begin
                    CntBurst <= 8'b0           ;
                    AxiLen   <= 8'b0           ;
                    AxiSize  <= 3'b0           ;
                    AxiAddr  <= 32'b0          ;
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    AxiId    <= 4'b0           ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(ArvalidSlave & ~AwvalidSlave)begin 
                        AxiState  <= `AXIREAD  ;
                    end 
                    if(AwvalidSlave & ~ArvalidSlave)begin 
                        AxiState  <= `AXIWRITE ;
                    end 
                    if(~AwvalidSlave & ~ArvalidSlave)begin 
                        AxiState  <= `AXIIDLE  ;
                    end 
                    
                end 
                `AXIREAD : begin
                    CntBurst <= 8'b0           ;
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(ArvalidSlave)begin 
                        AxiState  <= `AXIREADING  ;
                        AxiLen    <= ArlenSlave   ;
                        AxiSize   <= ArsizeSlave  ;
                        AxiAddr   <= AraddrSlave  ;
                        AxiId     <= AridSlave    ;
                    end 
                    else begin
                        AxiState  <= `AXIIDLE  ;
                        AxiLen    <= 8'b0      ;
                        AxiSize   <= 3'b0      ;
                        AxiAddr   <= 32'b0     ;
                        AxiId     <= 4'b0      ;
                    end
                end
                `AXIWRITE : begin
                    CntBurst <= 8'b0           ;
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(AwvalidSlave) begin
                        AxiState  <= `AXIWRITEGET    ;
                        AxiLen    <= AwlenSlave      ;
                        AxiSize   <= AwsizeSlave     ;
                        AxiAddr   <= AwaddrSlave     ;
                        AxiId     <= AwidSlave       ;
                    end
                    else begin 
                        AxiState    <= `AXIIDLE  ;
                        AxiLen      <= 8'b0      ;
                        AxiSize     <= 3'b0      ;
                        AxiAddr     <= 32'b0     ;
                        AxiId       <= 4'b0      ;
                    end 
                end
                `AXIREADING : begin
                    AxiLen    <= AxiLen   ;
                    AxiSize   <= AxiSize  ;
                    AxiAddr   <= AxiAddr  ;
                    AxiId     <= AxiId    ;
                    CntBurst  <= CntBurst     ;
                    AxiInData <= 32'b0        ;
                    AxiMask   <= AxiMask      ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(DataSuccess) begin
                        AxiState <= `AXIREADBURST    ;
                    end
                    else begin
                        AxiState <= `AXIREADING      ;
                    end
                end
                `AXIREADBURST : begin
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    if(CntBurst < AxiLen-1) begin 
                        AxiState <= `AXIREADING    ;
                        CntBurst <= CntBurst + 1   ;
                        AxiLen   <= AxiLen         ;
                        AxiSize  <= AxiSize        ;
                        AxiId    <= AxiId          ;
                        AxiAddr  <= AxiAddr + {28'b0,NumberData} ;
                        // IssueRead<= 1'b1           ;
                        // IssueWrite<= 1'b0          ;
                    end 
                    else begin
                        AxiState <= `AXIIDLE       ;
                        CntBurst <= 8'b0           ;
                        AxiLen   <= 8'b0           ;
                        AxiSize  <= 3'b0           ;
                        AxiAddr  <= 32'b0          ;
                        AxiId    <= 4'b0           ;
                        // IssueRead<= 1'b0           ;
                        // IssueWrite<= 1'b0          ;
                    end
                end
                `AXIWRITEGET : begin
                    AxiLen    <= AxiLen   ;
                    AxiSize   <= AxiSize  ;
                    AxiAddr   <= AxiAddr  ;
                    AxiId     <= AxiId    ;
                    CntBurst  <= CntBurst ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(WvalidSlave)begin
                        AxiState  <= `AXIWRITEING ;
                        AxiInData <= WdataSlave   ;
                        AxiMask   <= WstrbSlave   ;
                    end 
                    else begin
                        AxiState  <= `AXIWRITEGET ;
                        AxiInData <= 32'b0        ;
                        AxiMask   <= 4'b0000      ;
                    end
                end
                `AXIWRITEING : begin
                    AxiLen    <= AxiLen   ;
                    AxiSize   <= AxiSize  ;
                    AxiAddr   <= AxiAddr  ;
                    AxiId     <= AxiId    ;
                    CntBurst  <= CntBurst ;
                    AxiInData <= AxiInData;
                    AxiMask   <= AxiMask  ;
                    // IssueRead<= 1'b0          ;
                    // IssueWrite<= 1'b0         ;
                    if(UnBazyWrite) begin
                        AxiState <= `AXIWRITEBURST   ;
                    end
                    else begin
                        AxiState <= `AXIWRITEING      ;
                    end
                end
                `AXIWRITEBURST : begin
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    if(CntBurst < AxiLen-1) begin 
                        AxiState <= `AXIWRITEGET   ;
                        CntBurst <= CntBurst + 1   ;
                        AxiLen   <= AxiLen         ;
                        AxiSize  <= AxiSize        ;
                        AxiId    <= AxiId          ;
                        AxiAddr  <= AxiAddr + {28'b0,NumberData};
                        // IssueRead<= 1'b0           ;
                        // IssueWrite<= 1'b1          ;
                    end 
                    else begin
                        AxiState <= `AXIBRESP      ;
                        CntBurst <= 8'b0           ;
                        AxiLen   <= 8'b0           ;
                        AxiSize  <= 3'b0           ;
                        AxiAddr  <= 32'b0          ;
                        AxiId    <= 4'b0           ;
                        // IssueRead<= 1'b0           ;
                        // IssueWrite<= 1'b0          ;
                    end
                end
                `AXIBRESP : begin
                    CntBurst <= CntBurst       ;
                    AxiLen   <= AxiLen         ;
                    AxiSize  <= AxiSize        ;
                    AxiId    <= AxiId          ;
                    AxiAddr  <= AxiAddr        ;
                    AxiInData<= AxiInData      ;
                    AxiMask  <= AxiMask        ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                    if(BreadySlave) begin
                        AxiState <= `AXIIDLE   ;
                    end
                    else begin
                        AxiState <= `AXIBRESP  ;
                    end
                end
                default: begin
                    AxiState <= `AXIREAD       ;
                    CntBurst <= 8'b0           ;
                    AxiLen   <= 8'b0           ;
                    AxiSize  <= 3'b0           ;
                    AxiId    <= 4'b0           ;
                    AxiAddr  <= 32'b0          ;
                    AxiInData<= 32'b0          ;
                    AxiMask  <= 4'b0           ;
                    // IssueRead<= 1'b0           ;
                    // IssueWrite<= 1'b0          ;
                end
            endcase
        end
    end

    assign AwreadySlave = (AxiState  == `AXIWRITE);
    assign ArreadySlave = (AxiState  == `AXIREAD) ;

    assign BidSlave     = AxiId ;
    assign BrespSlave   = 2'b00 ;
    assign BvalidSlave  = (AxiState == `AXIBRESP) ;

    reg [3:0] RBurstState ; 
    reg       DataInDone  ;
    reg [31:0]ReadData    ;
    reg [31:0]ReadAddr    ;
    reg [3:0] RBurstSize  ; 
    reg [3:0] RBurstSize1 ;  
    reg [1:0] RAddrAdd    ;
    reg       WriteFifo1  ;
    reg       ReadBytefur ; 
    reg [1:0] ReadMask    ;

    wire      Fifo1Full    ;
    wire      Fifo2Empty   ;
    wire[15:0]FifoData    ;

    assign DataSuccess = DataInDone ;

    assign RidSlave    =  AxiId     ;
    assign RdataSlave  =  ReadData  ;
    assign RrespSlave  =  2'b00     ;
    assign RlastSlave  = (CntBurst == AxiLen-1) && RvalidSlave ;
    assign RvalidSlave = (RBurstState == `RBURSTTRANS) ;


    always @(posedge AxiClk) begin
        if(!AxiRest) begin
            RBurstState <= `RBURSTIDLE ;
            DataInDone  <= 1'b0        ;
            ReadData    <= 32'b0       ;
            RBurstSize  <= 4'b0        ;
            RBurstSize1 <= 4'b0        ;
            ReadAddr    <= 32'b0       ;
            RAddrAdd    <= 2'b0        ;
            WriteFifo1  <= 1'b0        ;
            ReadBytefur <= 1'b0        ;
            ReadMask    <= 2'b0        ;
        end 
        else begin
            case (RBurstState)
                `RBURSTIDLE : begin  
                    WriteFifo1  <= 1'b0        ;
                    ReadMask    <= 2'b0        ;
                    RBurstState <= (AxiState == `AXIREADING) ? `RBURSTREADIN : `RBURSTIDLE ;
                    DataInDone  <= 1'b0 ;
                    ReadData    <= 32'b0       ;
                    RBurstSize  <= (AxiState == `AXIREADING) ? NumberData : 4'b0  ;
                    RBurstSize1 <= (AxiState == `AXIREADING) ? NumberData : 4'b0  ;
                    ReadAddr    <= (AxiState == `AXIREADING) ? AxiAddr    : 32'b0 ;
                    ReadBytefur <= (AxiState == `AXIREADING) ? ((NumberData == 4'd4) ? 1'b1 : 1'b0) : 1'b0  ;
                    RAddrAdd    <= 2'b0        ;
                end
                `RBURSTREADIN : begin
                    ReadData <= 32'b0          ;
                    DataInDone  <= DataInDone  ;
                    RBurstSize  <= RBurstSize  ;
                    ReadBytefur <= ReadBytefur ;
                    if(!Fifo1Full) begin
                        RBurstState <= (RBurstSize1 <= 4'd2) ? `RBURSTREADOU : `RBURSTREADIN ;
                        RAddrAdd    <= (RBurstSize1 <= 4'd2) ? 2'd0          : 2'd2          ;
                        ReadAddr    <= ReadAddr + {30'd0,RAddrAdd}   ;
                        RBurstSize1 <= (RBurstSize1 <= 4'd2) ? RBurstSize1 : RBurstSize1 - 4'd2 ;
                        WriteFifo1  <= 1'b1        ;
                        ReadMask    <= (RBurstSize == 1) ? 2'b01 : 2'b11      ;
                    end
                    else begin
                        RBurstState <= `RBURSTREADIN ;
                        ReadAddr    <= ReadAddr      ;
                        RBurstSize1 <= RBurstSize1   ;
                        ReadBytefur <= ReadBytefur   ;
                        WriteFifo1  <= 1'b0          ;
                        ReadMask    <= ReadMask      ;
                    end
                end
                `RBURSTREADOU : begin
                    RBurstSize1 <= 3'b0          ;
                    RAddrAdd    <= 2'b0          ;
                    ReadMask    <= 2'b0          ;
                    if(!Fifo2Empty)begin
                        RBurstState <= (RBurstSize  <= 4'd2) ? `RBURSTTRANS : `RBURSTREADOU ;
                        DataInDone  <= (RBurstSize  <= 4'd2) ? `TURE        : `FALSE        ;
                        ReadData    <= (ReadBytefur        ) ? {FifoData,ReadData[31:16]} : {16'b0,FifoData};
                        RBurstSize  <= (RBurstSize  <= 4'd2) ? RBurstSize  : RBurstSize - 4'd2 ;
                        ReadAddr    <= ReadAddr    ;
                        WriteFifo1  <= 1'b0        ;
                    end
                    else begin
                        RBurstState <= RBurstState ;
                        DataInDone  <= DataInDone  ;
                        ReadData    <= ReadData    ;
                        RBurstSize  <= RBurstSize  ;
                        ReadAddr    <= ReadAddr    ;
                        ReadBytefur <= ReadBytefur ;
                        WriteFifo1  <= 1'b0        ;
                    end
                end
                `RBURSTTRANS : begin
                    RBurstSize1 <= 4'b0        ;
                    RAddrAdd    <= 2'b0        ;
                    ReadMask    <= 2'b0        ;
                    ReadData    <= ReadData    ;
                    RBurstSize  <= 4'b0        ;
                    ReadAddr    <= 32'b0       ;
                    WriteFifo1  <= 1'b0        ;
                    ReadBytefur <= 1'b0        ;
                    if(RreadySlave) begin
                        RBurstState <= `RBURSTIDLE ;
                        DataInDone  <= 1'b0        ;
                    end
                    else begin
                        RBurstState <= `RBURSTTRANS ;
                        DataInDone  <= DataInDone   ;
                    end
                end
                default: begin
                    RBurstState <= `RBURSTIDLE ;
                    DataInDone  <= 1'b0        ;
                    ReadData    <= 32'b0       ;
                    RBurstSize  <= 4'b0        ;
                    RBurstSize1 <= 4'b0        ;
                    ReadAddr    <= 32'b0       ;
                    RAddrAdd    <= 2'b0        ;
                    WriteFifo1  <= 1'b0        ;
                    ReadBytefur <= 1'b0        ;
                    ReadMask    <= 2'b0        ;
                end
            endcase
        end      
    end


    

    reg [3:0] WBurstState ;
    reg       DataOutDone ;
    reg [15:0]WriteData   ;
    reg [3:0 ]WBurstSize  ;
    reg [31:0]WriteAddr   ;
    reg [1:0] WriteMask   ;
    reg [1:0] WAddrAdd    ;
    reg       WriteFifo11 ;

    assign UnBazyWrite = DataOutDone ;
    assign WreadySlave = (AxiState == `AXIWRITEGET) ;

    always @(posedge AxiClk) begin
        if(!AxiRest) begin
            WBurstState <= `WBRUSTIDLE ;
            DataOutDone <= 1'b0        ;
            WriteData   <= 16'b0       ;
            WBurstSize  <= 4'b0        ;
            WriteAddr   <= 32'b0       ;
            WriteMask   <= 2'b0        ;
            WAddrAdd    <= 2'b0        ;
            WriteFifo11 <= 1'b0        ;
        end
        else begin
            case (WBurstState)
                `WBRUSTIDLE : begin
                     WAddrAdd    <= 2'b0        ;
                     WriteFifo11 <= 1'b0        ;
                     WriteMask   <= 2'b0        ;
                     WriteData   <= 16'b0       ;
                     WBurstState <= (AxiState == `AXIWRITEING) ? `WBURSTWRITEIN : `WBRUSTIDLE ;
                     DataOutDone <= 1'b0        ;
                     WBurstSize  <= (AxiState == `AXIWRITEING) ? NumberData     : 4'b0        ;
                     WriteAddr   <= (AxiState == `AXIWRITEING) ? AxiAddr        : 32'b0       ;
                end 
                `WBURSTWRITEIN : begin
                    if(!Fifo1Full) begin
                        WBurstState <= (WBurstSize <= 4'd2) ? `WBURSTWRITE : `WBURSTWRITEIN ;
                        DataOutDone <= (WBurstSize <= 4'd2) ? 1'b1 : 1'b0  ;
                        WriteData   <= (WAddrAdd   == 2'd0) ? AxiInData[15:0] : AxiInData[31:16] ;
                        WBurstSize  <= (WBurstSize <= 4'd2) ? WBurstSize : WBurstSize - 4'd2  ;
                        WriteAddr   <= WriteAddr +  {30'd0,WAddrAdd} ;
                        WriteMask   <= (WBurstSize == 1)    ? 2'b01 : 2'b11      ;
                        WAddrAdd    <= (WBurstSize <= 4'd2) ? 2'b0 : 2'd2        ;
                        WriteFifo11 <= 1'b1        ;
                    end
                    else begin
                        WBurstState <= WBurstState ;
                        DataOutDone <= DataOutDone ;
                        WriteData   <= WriteData   ;
                        WBurstSize  <= WBurstSize  ;
                        WriteAddr   <= WriteAddr   ;
                        WriteMask   <= WriteMask   ;
                        WAddrAdd    <= WAddrAdd    ;
                        WriteFifo11 <= 1'b0        ;
                    end 
                end
                `WBURSTWRITE : begin
                    WBurstState <= `WBRUSTIDLE ;
                    DataOutDone <= 1'b0        ;
                    WriteData   <= 16'b0       ;
                    WBurstSize  <= 4'b0        ;
                    WriteAddr   <= 32'b0       ;
                    WriteMask   <= 2'b0        ;
                    WAddrAdd    <= 2'b0        ;
                    WriteFifo11 <= 1'b0        ;
                end
                default:  begin
                    WBurstState <= `WBRUSTIDLE ;
                    DataOutDone <= 1'b0        ;
                    WriteData   <= 16'b0       ;
                    WBurstSize  <= 4'b0        ;
                    WriteAddr   <= 32'b0       ;
                    WriteMask   <= 2'b0        ;
                    WAddrAdd    <= 2'b0        ;
                    WriteFifo11 <= 1'b0        ;
                end
            endcase
        end 
    end



    //addr + data + mask + RorW 

    wire                  WriteFifo1En   ;
    wire [32+16+2+2-1:0]  WriteFifo1Data ;

    assign WriteFifo1En   = WriteFifo1 || WriteFifo11 ;
    assign WriteFifo1Data = WriteFifo1 ? {ReadAddr, 16'd0, ReadMask, 2'b01} : //read == 2'b01  write == 2'b10 
                            WriteFifo11? {WriteAddr,WriteData,WriteMask,2'b10} : {32+16+2+2{1'b0}};

    wire                 Fifo1Empty   ;  
    wire [31:0]          Fifo1InAddr  ;
    wire [15:0]          Fifo1InData  ;
    wire [1:0]           Fifo1InMask  ;
    wire [1:0]           Fifo1InRorW  ;
    wire                 Fifo1ReadEn  ;
    //wire                 Fifo1Full    ;

    NsyncFifo#(                           //               bank      line      clum
        .WIDTH      ( 32+16+2+2        ), //对于32位addr ：25---24    23---11   10---1
        .DEPTH      ( 16'd4            ),
        .WRFAST     ( `FALSE           ),
        .RDFAST     ( `TURE            )
    )CommandU1(
        .wr_clk      ( AxiClk           ),
        .wr_reset_n  ( AxiRest          ),
        .wr_en       ( WriteFifo1En     ),
        .wr_data     ( WriteFifo1Data   ),
        .full        (                  ),
        .afull       ( Fifo1Full        ),
        .rd_clk      ( SdramClk         ),
        .rd_reset_n  ( SdramRest        ),
        .rd_en       ( Fifo1ReadEn      ),
        .empty       ( Fifo1Empty       ),
        .aempty      (                  ),
        .rd_data     ( {Fifo1InAddr    ,
                        Fifo1InData    ,
                        Fifo1InMask    ,
                        Fifo1InRorW   } )
    );

    wire             WriteFifo2En      ;
    wire [15:0]      WriteFifo2Data    ;

    wire                  ReadFifo2En    ;
    wire [15:0         ]  ReadFifo2Data  ;

    assign ReadFifo2En    = (RBurstState == `RBURSTREADOU) & ~Fifo2Empty ;
    assign FifoData       =  ReadFifo2Data  ;

    NsyncFifo#(
        .WIDTH      ( 16               ), 
        .DEPTH      ( 16'd4            ), //最大不会超过4×16 = 64 所以不会空也不会满 ;
        .WRFAST     ( `FALSE           ),
        .RDFAST     ( `TURE            )
    )CommandU2(
        .wr_clk      ( SdramClk        ),
        .wr_reset_n  ( SdramRest       ),
        .wr_en       ( WriteFifo2En    ),
        .wr_data     ( WriteFifo2Data  ),
        .full        (                 ),
        .afull       (                 ),
        .rd_clk      ( AxiClk          ),
        .rd_reset_n  ( AxiRest         ),
        .rd_en       ( ReadFifo2En     ),
        .empty       ( Fifo2Empty      ),
        .aempty      (                 ),
        .rd_data     ( ReadFifo2Data   )
    );

    //##########################Sdram Clock Are#############################//


    wire            ArefRequest   ;
    wire            AutoRefFinish ;
    wire  [12:0]    ArefModeData  ;
    wire  [3:0]     ArefCMDDate   ;
    wire            InArefState   ;

    SdramAref#(
    .SDRAMMHZ   ( SDRAMMHZ     )
    )u_SdramAref(
        .Clk        ( SdramClk     ),
        .Rest       ( SdramRest    ),
        .SdramGetS  ( InArefState  ),
        .ArefReq    ( ArefRequest  ),
        .ArefCmd    ( ArefCMDDate  ),
        .ArefMode   ( ArefModeData ),
        .ArefDone   ( AutoRefFinish)

    );

    wire            SdramInitFinsh ;
    wire [12:0]     InitModeData   ;
    wire [3:0]      InitCMDData    ;

    SdramInit#(
        .SDRAMMHZ       ( SDRAMMHZ        )
    )u_SdramInit(
        .Clk            ( SdramClk        ),
        .Rest           ( SdramRest       ),
        .ReInit         ( 1'b0            ),
        .SdramCmd       ( InitCMDData     ),
        .SdramMode      ( InitModeData    ),
        .SdramInitDone  ( SdramInitFinsh  )
    );


    reg [7:0]  SdramState   ;
    // reg        ReadChannl   ;
    // reg        WriteChannl  ;
    reg        ReadFifo1    ;
    reg        WriteFifo2   ;
    reg [1:0]  TempBank     ;
    reg [12:0] TempLine     ;
    reg [1:0]  TempOpt      ;
    reg [15:0] TempData     ;
    reg [9:0]  TempClum     ;
    reg [1:0]  TempMask     ;
    reg [7:0]  SdramCnt     ;

    assign InArefState = (SdramState == `SCOREAREF) ;

    always @(posedge SdramClk) begin
        if(!SdramRest) begin
            SdramState <= `SCOREINIT ;
            SdramCnt   <= 8'b0       ;
            ReadFifo1  <= `FALSE     ;
            WriteFifo2 <= `FALSE     ;
            TempBank   <= 2'b00      ;
            TempLine   <= 13'd0      ;
            TempClum   <= 10'b0      ;
            TempOpt    <= 2'b00      ;
            TempData   <= 16'b0      ;
            TempMask   <= 2'b0       ;
        end
        else begin
            case (SdramState)
                `SCOREINIT : begin
                    SdramCnt   <= 8'b0       ;
                    ReadFifo1  <= `FALSE     ;
                    WriteFifo2 <= `FALSE     ;
                    TempBank   <= 2'b00      ;
                    TempLine   <= 13'd0      ;
                    TempClum   <= 10'b0      ;
                    TempOpt    <= 2'b00      ;
                    TempData   <= 16'b0      ;
                    TempMask   <= 2'b0       ;
                    if(SdramInitFinsh)begin
                        SdramState <= `SCOREIDLE ;
                    end
                    else begin
                        SdramState <= `SCOREINIT ;
                    end
                end 
                `SCOREIDLE : begin
                    TempBank   <= TempBank      ;
                    TempLine   <= TempLine      ;
                    TempClum   <= 10'b0         ;
                    TempOpt    <= TempOpt       ;
                    TempData   <= 16'b0         ;
                    TempMask   <= 2'b0          ;
                    SdramCnt   <= 8'b0          ;
                    if(ArefRequest) begin
                        SdramState <= `SCOREAREF ;
                        ReadFifo1  <= `FALSE     ;
                        WriteFifo2 <= `FALSE     ;
                    end 
                    else if(!Fifo1Empty) begin
                        SdramState <= `SCOREANYLZ;
                        ReadFifo1  <= `TURE      ;
                        WriteFifo2 <= `FALSE     ;
                    end
                    else begin
                        SdramState <= `SCOREIDLE ;
                        ReadFifo1  <= `FALSE     ;
                        WriteFifo2 <= `FALSE     ;
                    end
                end
                `SCOREANYLZ : begin
                    TempBank   <= Fifo1InAddr[24:23]      ;
                    TempLine   <= Fifo1InAddr[22:10]      ;
                    TempClum   <= Fifo1InAddr[9:0]        ;
                    TempOpt    <= Fifo1InRorW             ;
                    TempData   <= (Fifo1InRorW == 2'b01) ? 16'b0       :
                                  (Fifo1InRorW == 2'b10) ? Fifo1InData : 16'b0 ;
                    TempMask   <= Fifo1InMask             ;
                    SdramCnt   <= 8'b0                    ;
                    if((TempBank != Fifo1InAddr[24:23]) || 
                       (TempLine != Fifo1InAddr[22:10]) || 
                       (TempOpt  != Fifo1InRorW       )) begin 
                       SdramState <= `SCOREPCHGE ;
                       ReadFifo1  <= `FALSE     ;
                       WriteFifo2 <= `FALSE     ;
                    end
                    else begin
                       SdramState <= (Fifo1InRorW == 2'b01) ? `SCOREREAD :
                                     (Fifo1InRorW == 2'b10) ? `SCOREWRITE : `SCOREIDLE ;
                       ReadFifo1  <= `FALSE     ;
                       WriteFifo2 <= `FALSE     ;
                    end 
                end
                `SCOREPCHGE : begin
                    TempBank   <= TempBank      ;
                    TempLine   <= TempLine      ;
                    TempClum   <= TempClum      ;
                    TempOpt    <= TempOpt       ;
                    TempData   <= TempData      ;
                    TempMask   <= TempMask      ;
                    ReadFifo1  <= `FALSE        ;
                    WriteFifo2 <= `FALSE        ;
                    if(SdramCnt == CYCNUMRP-1) begin 
                        // SdramState   <= (TempOpt == 2'b01) ? `SCOREREAD :
                        //                 (TempOpt == 2'b10) ? `SCOREWRITE : `SCOREIDLE ;
                        SdramState   <= `SCOREACTIVE  ;
                        SdramCnt     <= 8'b0          ;    
                    end 
                    else begin
                        SdramState   <= `SCOREPCHGE    ;
                        SdramCnt     <= SdramCnt + 1   ;
                    end
                end
                `SCOREACTIVE : begin
                    TempBank   <= TempBank      ;
                    TempLine   <= TempLine      ;
                    TempClum   <= TempClum      ;
                    TempOpt    <= TempOpt       ;
                    TempData   <= TempData      ;
                    TempMask   <= TempMask      ;
                    ReadFifo1  <= `FALSE        ;
                    WriteFifo2 <= `FALSE        ;
                    if(SdramCnt == CYCNURCD-1) begin
                        SdramState   <= (TempOpt == 2'b01) ? `SCOREREAD :
                                        (TempOpt == 2'b10) ? `SCOREWRITE : `SCOREIDLE ;
                        SdramCnt     <= 8'b0          ;  
                    end
                    else begin
                        SdramState   <= `SCOREACTIVE   ;
                        SdramCnt     <= SdramCnt + 1   ;
                    end
                end
                `SCOREREAD : begin
                    TempBank   <= TempBank      ;
                    TempLine   <= TempLine      ;
                    TempClum   <= TempClum      ;
                    TempOpt    <= TempOpt       ;
                    TempMask   <= TempMask      ;
                    ReadFifo1  <= `FALSE        ;
                    if(SdramCnt == 1) begin //潜伏期1
                        SdramState <= `SCOREIDLE ;
                        SdramCnt   <= 8'b0       ;
                        WriteFifo2 <= `TURE      ;
                        TempData   <= ChipDq     ;
                    end 
                    else begin
                        SdramState <= `SCOREREAD   ;
                        SdramCnt   <= SdramCnt + 1 ;
                        WriteFifo2 <= `FALSE       ;
                        TempData   <= 16'b0        ;
                    end
                end
                `SCOREWRITE : begin
                    TempBank   <= TempBank      ;
                    TempLine   <= TempLine      ;
                    TempClum   <= TempClum      ;
                    TempOpt    <= TempOpt       ;
                    TempMask   <= TempMask      ;
                    TempData   <= TempData      ;
                    ReadFifo1  <= `FALSE        ;
                    WriteFifo2 <= `FALSE        ;
                    SdramState <= `SCOREIDLE    ;
                    SdramCnt   <= 8'b0          ;
                end
                `SCOREAREF : begin
                    SdramCnt   <= 8'b0       ;
                    ReadFifo1  <= `FALSE     ;
                    WriteFifo2 <= `FALSE     ;
                    TempBank   <= 2'b00      ;
                    TempLine   <= 13'd0      ;
                    TempClum   <= 10'b0      ;
                    TempOpt    <= 2'b00      ;
                    TempData   <= 16'b0      ;
                    TempMask   <= 2'b0       ;
                    if(AutoRefFinish) begin
                        SdramState <= `SCOREIDLE ;
                    end
                    else begin
                        SdramState <= `SCOREAREF ;
                    end
                end
                default: begin
                    SdramState <= `SCOREINIT ;
                    SdramCnt   <= 8'b0       ;
                    ReadFifo1  <= `FALSE     ;
                    WriteFifo2 <= `FALSE     ;
                    TempBank   <= 2'b00      ;
                    TempLine   <= 13'd0      ;
                    TempClum   <= 10'b0      ;
                    TempOpt    <= 2'b00      ;
                    TempData   <= 16'b0      ;
                    TempMask   <= 2'b0       ;
                end
            endcase
        end
    end

    assign WriteFifo2En     = WriteFifo2 ;
    assign WriteFifo2Data   = TempData   ;

    assign Fifo1ReadEn      = ReadFifo1  ;


    wire                InInitState     ;
    assign InInitState      = (SdramState == `SCOREINIT) ;
    wire                InIdleState     ;
    assign InIdleState      = (SdramState == `SCOREIDLE) ;
    wire                InAnylizeState  ;
    assign InAnylizeState   = (SdramState == `SCOREANYLZ);
    wire                InPrechargeState;
    assign InPrechargeState = (SdramState == `SCOREPCHGE)&&(SdramCnt == 8'b0); 
    wire                InRowactiveState;
    assign InRowactiveState = (SdramState == `SCOREACTIVE)&&(SdramCnt == 8'b0);      
    wire                InReadState     ;
    assign InReadState      = (SdramState == `SCOREREAD)&&(SdramCnt == 8'b0) ;
    wire                InWriteState    ;
    assign InWriteState     = (SdramState == `SCOREWRITE)&&(SdramCnt == 8'b0);
    wire                InAutorefState  ;
    assign InAutorefState   = (SdramState == `SCOREAREF) ;


    assign ChipDq     = InInitState      ? 16'b0     :
                        InIdleState      ? 16'b0     :
                        InAnylizeState   ? 16'b0     :
                        InPrechargeState ? 16'b0     :
                        InRowactiveState ? 16'b0     :
                        (SdramState == `SCOREREAD) ? 16'bz     :
                        InWriteState     ? TempData  : 
                        InAutorefState   ? 16'b0     : 16'b0  ;
    assign ChipAddr   = InInitState      ? InitModeData       :
                        InIdleState      ? 13'b0              :
                        InAnylizeState   ? 13'b0              :
                        InPrechargeState ? {2'b0,1'b1,10'b0}  :
                        InRowactiveState ? TempLine           : 
                        InReadState      ? {2'b0,1'b0,TempClum}    :
                        InWriteState     ? {2'b0,1'b0,TempClum}    :
                        InAutorefState   ? ArefModeData       : 13'b0 ;
    assign ChipBank   = InInitState      ? 2'b0               :
                        InIdleState      ? 2'b0               :
                        InAnylizeState   ? 2'b0               :
                        InPrechargeState ? 2'b0               :
                        InRowactiveState ? TempBank           :
                        InReadState      ? TempBank           :
                        InWriteState     ? TempBank           : 
                        InAutorefState   ? 2'b0               : 2'b0 ;
    assign ChipClk    = ~SdramClk ;//Sdram要在数据稳定时采集数据。
    assign ChipCke    = `TURE; //内部时钟使能，关闭则为低功耗，这里恒为真。
    assign {ChipCs_n ,
            ChipRas_n,
            ChipCas_n,
            ChipWe_n} = InInitState     ? InitCMDData        :
                        InIdleState     ? `NOPC              :
                        InAnylizeState  ? `NOPC              :
                        InPrechargeState? `PRECHAGE          :
                        InRowactiveState? `ROWACTIVE         :
                        InReadState     ? `READC             :
                        InWriteState    ? `WRITEC            :
                        InAutorefState  ? ArefCMDDate        : `NOPC ;
    assign ChipDqm    = InInitState     ? ~2'b00              :
                        InIdleState     ? ~2'b00              :
                        InAnylizeState  ? ~2'b00              :
                        InPrechargeState? ~2'b00              :
                        InRowactiveState? ~2'b00              :
                        InReadState     ? ~TempMask           :
                        InWriteState    ? ~TempMask           :
                        InAutorefState  ? ~2'b00              : ~2'b00 ;

    endmodule
