/*********************************************************************
                                                              
    AXI转SDRAM               
    描述: 输入AXI从机接口输出SDRAM控制器接口   
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.8  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "NsyncFifo.v"
`include "SdramCore.v"
`include "define.v"
module AxiToSdram #(
        //TODO : 请指定SDRAM的工作频率，SDRAM每bank的行数，SDRAM每行存储单元数，
        //       SDRAM每单元bit数，AXI的数据宽度，AXI的地址宽度。
    parameter     SDRAMMHZ      =        100       ,
    parameter     SDRAMLINE     =        2048      ,
    parameter     SDRAMCLUM     =        256       ,
    parameter     SDRAMWIDTH    =        32        , // 和syncfifow相同
    parameter     FIFODEPTH     =        16        , // 此为syncfifow的深度，建议不用修改，过大过小都不宜
    parameter     AXIWIDTH      =        32        , // 支持64/32
    parameter     AXIADDRW      =        32         
) (
    input       wire                                                AxiClk         ,
    input       wire                                                AxiRest        ,
    input       wire                                                SdramClk       ,
    input       wire                                                SdramRest      ,

    input       wire  [`AXIID                                     ] AwidSlave      ,
    input       wire  [AXIADDRW-1:0                               ] AwaddrSlave    , //sdram的地址范围导致会有一部分no used
    input       wire  [`AXILEN                                    ] AwlenSlave     ,
    input       wire  [`AXISIZE                                   ] AwsizeSlave    ,
    input       wire  [`AXIBURST                                  ] AwburstSlave   ,
    input       wire                                                AwlockSlave    , //暂时不支持原子访问，如果需要后续在添加，或者直接用户软实现
    input       wire  [`AXICACHE                                  ] AwcacheSlave   , //主要用于缓存和一致性，这里不会使用，目前所支持的状态为x01x，即nubuffer and canmodify
    input       wire  [`AXIPORT                                   ] AwportSlave    , //由于sdram并不需要知道安全类型，所以忽略该信号   
    input       wire                                                AwvalidSlave   ,
    output      wire                                                AwreadySlave   ,

    input       wire  [`AXIID                                     ] WidSlave       ,
    input       wire  [AXIWIDTH-1:0                               ] WdataSlave     ,
    input       wire  [`AXISTRB                                   ] WstrbSlave     ,
    input       wire                                                WlastSlave     ,
    input       wire                                                WvalidSlave    ,
    output      wire                                                WreadySlave    ,

    output      wire  [`AXIID                                     ] BidSlave       , //sdram写通道如果发生写错误就会直接stop，所以可以直接回传okey信息
    output      wire  [`AXIRESP                                   ] BrespSlave     ,
    output      wire                                                BvalidSlave    ,
    input       wire                                                BreadySlave    ,

    input       wire  [`AXIID                                     ] AridSlave      ,
    input       wire  [AXIADDRW-1:0                               ] AraddrSlave    ,
    input       wire  [`AXILEN                                    ] ArlenSlave     ,
    input       wire  [`AXISIZE                                   ] ArsizeSlave    ,
    input       wire  [`AXIBURST                                  ] ArBurstSlave   ,
    input       wire                                                ArlockSlave    ,
    input       wire  [`AXICACHE                                  ] ArcacheSlave   ,
    input       wire  [`AXIPORT                                   ] ArportSlave    ,
    input       wire                                                ArvalidSlave   ,
    output      wire                                                ArreadySlave   ,

    output      wire  [`AXIID                                     ] RidSlave       ,
    output      wire  [AXIWIDTH-1:0                               ] RdataSlave     ,
    output      wire  [`AXIRESP                                   ] RrespSlave     ,
    output      wire                                                RlastSlave     ,
    output      wire                                                RvalidSlave    ,
    input       wire                                                RreadySlave    ,

    inout       wire  [SDRAMWIDTH-1 : 0                           ] Dq             ,
    output      wire  [$clog2(SDRAMLINE)-1:0                      ] Addr           ,
    output      wire  [1 : 0                                      ] Bank           ,
    output      wire                                                Clk            ,
    output      wire                                                Cke            , 
    output      wire                                                Cs_n           ,
    output      wire                                                Ras_n          ,
    output      wire                                                Cas_n          ,
    output      wire                                                We_n           ,
    output      wire  [(SDRAMWIDTH/8)-1:0                         ] Dqm
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

    parameter ADDRWIDTH = 2 + $clog2(SDRAMLINE-1) + $clog2(SDRAMCLUM-1) + $clog2(SDRAMWIDTH/8-1) ;

    wire Command1Full ;
    wire Command2Full ;
    wire Command3Full ;
    wire Command1Empty;
    wire Command2Empty;
    wire Command3Empty;

    reg [7:0] AxiState   ;
    reg [3:0] AxiWriteId ;
    reg       ReadyWrite ;
    reg       ReadyRead  ;


    always @(posedge AxiClk) begin
        if(!AxiRest) begin
            ReadyRead   <= `FALSE   ;
            ReadyWrite  <= `FALSE   ;
            AxiState    <= `AXIIDLE ;
            AxiWriteId  <= 4'b0     ;
        end
        else begin
            case (AxiState)
                `AXIIDLE  : begin
                    AxiWriteId  <= 4'b0     ;
                    if(ArvalidSlave & !Command1Full)begin 
                        AxiState  <= `AXIREAD  ;
                        ReadyRead <= `TURE     ;
                        ReadyWrite<= `FALSE    ;
                    end 
                    if(AwvalidSlave & ~ArvalidSlave & !Command1Full)begin 
                        AxiState  <= `AXIWRITE ;
                        ReadyRead <= `FALSE    ;
                        ReadyWrite<= `TURE     ;
                    end 
                    if(~AwvalidSlave & ~ArvalidSlave)begin 
                        AxiState  <= `AXIIDLE  ;
                        ReadyRead <= `FALSE    ;
                        ReadyWrite<= `FALSE    ;
                    end 
                end 
                `AXIREAD  : begin //这里我进行一些简化操作，我认为这么也是没什么影响的，
                ///就是，每次当读信号被相应的时候，在这个读的进程没有被完成的时候不会在接收任何读信号。
                //并且还有一个考虑就是，sdram只能在某一时间相应读或这写。
                    if(ArvalidSlave & ReadyRead)begin 
                        AxiWriteId<= AridSlave ;
                        ReadyRead <= `FALSE    ;
                        ReadyWrite<= `FALSE    ;
                        AxiState  <= `AXIWEITERF;
                    end 
                    else begin
                        AxiWriteId<= 4'b0      ;
                        ReadyRead <= `FALSE    ;
                        ReadyWrite<= `FALSE    ;
                        AxiState  <= `AXIIDLE  ;
                    end
                end
                `AXIWRITE : begin
                    ReadyRead <= `FALSE    ;
                    ReadyWrite<= `FALSE    ;
                    if(AwvalidSlave & ReadyWrite) begin
                        AxiWriteId<= AwidSlave    ;
                        AxiState  <= `AXIGETDATA  ;
                    end
                    else begin 
                    AxiState    <= `AXIIDLE  ;
                    AxiWriteId  <= 4'b0      ;
                    end 
                end
                `AXIGETDATA: begin
                    AxiWriteId <= AxiWriteId ;
                    ReadyRead <= `FALSE      ;
                    ReadyWrite<= `FALSE      ;
                    if(WlastSlave)begin 
                        AxiState  <= `AXIWRESP   ;
                    end 
                    else begin
                        AxiState  <= `AXIGETDATA ;
                    end  
                end
                `AXIWEITERF : begin
                        AxiWriteId<= AxiWriteId;
                        ReadyRead <= `FALSE    ;
                        ReadyWrite<= `FALSE    ;
                    if(RlastSlave)begin
                        AxiState  <= `AXIIDLE  ;
                    end
                    else begin
                        AxiState  <= `AXIWEITERF;
                    end
                end
                `AXIWRESP  : begin
                    ReadyRead <= `FALSE    ;
                    ReadyWrite<= `FALSE    ;
                    if(BreadySlave) begin
                        AxiState   <= `AXIIDLE   ;
                        AxiWriteId <= 4'b0       ;
                    end
                    else begin
                        AxiState   <= `AXIWRESP  ;
                        AxiWriteId <= AxiWriteId ;
                    end
                end
                default: begin
                    ReadyRead   <= `FALSE   ;
                    ReadyWrite  <= `FALSE   ;
                    AxiState    <= `AXIIDLE ;
                    AxiWriteId  <= 4'b0     ;
                end
            endcase
        end
    end

    wire                           InFifo1WriteOrRead ;
    wire [ADDRWIDTH-1:0]           InFifo1Addr        ;
    wire [`AXILEN]                 InFifo1WriteLen    ;
    wire [`AXIID ]                 InFifo1ReadId      ;
    wire                           InFifo1En          ;
    wire [`AXISIZE]                InFifo1Size        ;
    wire [`AXIBURST]               InFifo1Burst       ;

    assign ArreadySlave = ReadyRead   ;
    assign AwreadySlave = ReadyWrite  ;

    assign InFifo1En = (((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE)) || 
                       ((ArvalidSlave && ArreadySlave) && (AxiState == `AXIREAD)))  ;

    assign InFifo1WriteOrRead = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? 1'b0 : 1'b1 ;
    assign InFifo1Addr        = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? AwaddrSlave[ADDRWIDTH-1:0] : AraddrSlave[ADDRWIDTH-1:0] ;
    assign InFifo1WriteLen    = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? AwlenSlave  : ArlenSlave  ;
    assign InFifo1ReadId      = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? AwidSlave   : AridSlave   ;
    assign InFifo1Size        = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? AwsizeSlave : ArsizeSlave ;
    assign InFifo1Burst       = ((AwvalidSlave && AwreadySlave) && (AxiState == `AXIWRITE))
                               ? AwburstSlave: ArBurstSlave;

    assign BidSlave           = (BvalidSlave && BreadySlave) ? AxiWriteId : 4'b0 ;
    assign BrespSlave         = 2'b00                                            ;
    assign BvalidSlave        = (AxiState  == `AXIWRESP)                         ;

    wire                           InFifo2En               ;
    assign WreadySlave        = (AxiState  == `AXIGETDATA) ;
    assign InFifo2En          = (WreadySlave && WvalidSlave)  && !Command2Full ;

    wire                           ReadFifo3ReadEn     ;
    wire  [AXIWIDTH-1:0]           ReadFifo3Data       ;  

    // reg      ReadFifo3En    ;
    // always @(posedge AxiClk) begin 
    //     if(!AxiRest) begin
    //         ReadFifo3En <= `FALSE ;
    //     end
    //     else begin
    //         if(!Command3Empty) begin
    //             ReadFifo3En <= `TURE ;
    //         end
    //         else begin
    //             ReadFifo3En <= `FALSE ;        
    //         end 
    //     end
    // end
    // assign ReadFifo3ReadEn = ReadFifo3En && ~AxiSlipTran ;

    reg  [`AXISIZE    ] Fifo3ReadSize ;
    reg  [`AXILEN     ] Fifo3ReadLen  ;
    reg  [`AXIID      ] Fifo3ReadId   ;
    reg  [3:0         ] Fifo3ReadState;
    reg  [AXIWIDTH-1:0] Fifo3ReadData ;
    reg                 AxiSlipTran   ;
    reg  [3:0         ] TransCnt      ;
    reg  [AXIWIDTH-1:0] FifoDataTemp  ;

    parameter SIZE1BYTE = (AXIWIDTH == 32) ? 4'd4 : 
                          (AXIWIDTH == 64) ? 4'd8 : 4'd0 ;

    parameter SIZE2BYTE = (AXIWIDTH == 32) ? 4'd2 : 
                          (AXIWIDTH == 64) ? 4'd4 : 4'd0 ;

    parameter SIZE4BYTE = (AXIWIDTH == 32) ? 4'd1 : 
                          (AXIWIDTH == 64) ? 4'd2 : 4'd0 ;

    wire InActRead = ((ArvalidSlave && ArreadySlave) && (AxiState == `AXIREAD)) ;

    always @(posedge AxiClk) begin
         if(!AxiRest)begin
            Fifo3ReadSize   <= 3'b0         ;
            Fifo3ReadLen    <= 8'b0         ;
            Fifo3ReadId     <= 4'b0         ;
            Fifo3ReadState  <= `AXIREADIDLE ;
            Fifo3ReadData   <= {AXIWIDTH{1'b0}};
            AxiSlipTran     <= 1'b0         ;
            TransCnt        <= 4'b0         ;
            FifoDataTemp    <= {AXIWIDTH{1'b0}};
         end
         else begin
            case (Fifo3ReadState)
                `AXIREADIDLE  : begin
                    if(InActRead) begin 
                        Fifo3ReadSize   <= ArsizeSlave         ;
                        Fifo3ReadLen    <= ArlenSlave          ;
                        Fifo3ReadId     <= AridSlave           ;
                        Fifo3ReadState  <= `AXIREADTRANS       ;
                        Fifo3ReadData   <= {AXIWIDTH{1'b0}}    ;
                        AxiSlipTran     <= 1'b0                ;
                        TransCnt        <= 4'b0                ;
                        FifoDataTemp    <= {AXIWIDTH{1'b0}}    ;
                    end  
                    else begin
                        Fifo3ReadSize   <= 3'b0                ;
                        Fifo3ReadLen    <= 8'b0                ;
                        Fifo3ReadId     <= 4'b0                ;
                        Fifo3ReadState  <= `AXIREADIDLE        ;
                        Fifo3ReadData   <= {AXIWIDTH{1'b0}}    ;
                        AxiSlipTran     <= 1'b0                ;
                        TransCnt        <= 4'b0                ;
                        FifoDataTemp    <= {AXIWIDTH{1'b0}}    ;
                    end
                end 
                `AXIREADTRANS : begin
                    if(Fifo3ReadLen > 0) begin
                        Fifo3ReadId   <= Fifo3ReadId   ;
                        Fifo3ReadSize <= Fifo3ReadSize ;
                        if(Fifo3ReadSize == 3'b000) begin
                            TransCnt      <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? TransCnt + 1'b1 : TransCnt)            : 4'b0;
                            Fifo3ReadData <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? {{AXIWIDTH-8{1'b0}},FifoDataTemp[7:0]} : {AXIWIDTH{1'b0}})  : {AXIWIDTH{1'b0}};
                            AxiSlipTran   <= (TransCnt < SIZE1BYTE) ? `TURE             : `FALSE           ;
                            Fifo3ReadLen  <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? Fifo3ReadLen - 1  : Fifo3ReadLen)       : Fifo3ReadLen   ;
                            FifoDataTemp  <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? FifoDataTemp >> 8 : FifoDataTemp)  : {AXIWIDTH{1'b0}}    ;
                            Fifo3ReadState<= (TransCnt < SIZE1BYTE) ? `AXIREADTRANS     : `AXIREADFIFO     ;  
                        end
                        else if(Fifo3ReadSize == 3'b001) begin
                            TransCnt      <= (TransCnt < SIZE2BYTE) ? (RreadySlave ? TransCnt + 1'b1 : TransCnt)        : 4'b0 ;
                            Fifo3ReadData <= (TransCnt < SIZE2BYTE) ? (RreadySlave ? {{AXIWIDTH-16{1'b0}},FifoDataTemp[15:0]} : {AXIWIDTH{1'b0}})  : {AXIWIDTH{1'b0}};
                            AxiSlipTran   <= (TransCnt < SIZE2BYTE) ? `TURE             : `FALSE           ;
                            Fifo3ReadLen  <= (TransCnt < SIZE2BYTE) ? (RreadySlave ? Fifo3ReadLen - 1   : Fifo3ReadLen)       : Fifo3ReadLen   ;
                            FifoDataTemp  <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? FifoDataTemp >> 16 : FifoDataTemp)  : {AXIWIDTH{1'b0}}    ;
                            Fifo3ReadState<= (TransCnt < SIZE1BYTE) ? `AXIREADTRANS     : `AXIREADFIFO     ; 
                        end
                        else if(Fifo3ReadSize == 3'b010) begin
                            TransCnt      <= (TransCnt < SIZE4BYTE) ? (RreadySlave ? TransCnt + 1'b1 : TransCnt)        : 4'b0  ;
                            Fifo3ReadData <= (TransCnt < SIZE4BYTE) ? (RreadySlave ? {{AXIWIDTH-32{1'b0}},FifoDataTemp[31:0]} : {AXIWIDTH{1'b0}})  : {AXIWIDTH{1'b0}};
                            AxiSlipTran   <= (TransCnt < SIZE4BYTE) ? `TURE             : `FALSE           ;
                            Fifo3ReadLen  <= (TransCnt < SIZE4BYTE) ? (RreadySlave ? Fifo3ReadLen - 1   : Fifo3ReadLen)       : Fifo3ReadLen   ;
                            FifoDataTemp  <= (TransCnt < SIZE1BYTE) ? (RreadySlave ? FifoDataTemp >> 32 : FifoDataTemp)  : {AXIWIDTH{1'b0}}    ;
                            Fifo3ReadState<= (TransCnt < SIZE1BYTE) ? `AXIREADTRANS     : `AXIREADFIFO     ; 
                        end
                        else if(Fifo3ReadSize == 3'b011) begin //这里是size=8的情况，那么就证明size=8只能在width为64的情况
                            TransCnt      <= (TransCnt < 1)         ? (RreadySlave ? TransCnt + 1'b1 : TransCnt)        : 4'b0  ;
                            Fifo3ReadData <= (TransCnt < 1)         ? (RreadySlave ? FifoDataTemp: {AXIWIDTH{1'b0}})  : {AXIWIDTH{1'b0}};
                            AxiSlipTran   <= (TransCnt < 1)         ? `TURE             : `FALSE           ;
                            Fifo3ReadLen  <= (TransCnt < 1)         ? (RreadySlave ? Fifo3ReadLen - 1   : Fifo3ReadLen)       : Fifo3ReadLen   ;
                            FifoDataTemp  <= (TransCnt < 1)         ? (RreadySlave ? FifoDataTemp       : FifoDataTemp)  : {AXIWIDTH{1'b0}}    ;
                            Fifo3ReadState<= (TransCnt < 1)         ? `AXIREADTRANS     : `AXIREADFIFO     ; 
                        end
                    end
                    else begin
                        Fifo3ReadSize   <= 3'b0                ;
                        Fifo3ReadLen    <= 8'b0                ;
                        Fifo3ReadId     <= 4'b0                ;
                        Fifo3ReadState  <= `AXIREADIDLE        ;
                        Fifo3ReadData   <= {AXIWIDTH{1'b0}}    ;
                        AxiSlipTran     <= 1'b0                ;
                        TransCnt        <= 4'b0                ;
                        FifoDataTemp    <= {AXIWIDTH{1'b0}}    ;
                    end
                end
                `AXIREADFIFO : begin
                    Fifo3ReadSize   <= Fifo3ReadSize       ;
                    Fifo3ReadLen    <= Fifo3ReadLen        ;
                    Fifo3ReadId     <= Fifo3ReadId         ;
                    Fifo3ReadData   <= {AXIWIDTH{1'b0}}    ;
                    AxiSlipTran     <= 1'b0                ;
                    TransCnt        <= 4'b0                ;
                    FifoDataTemp    <= ReadFifo3Data       ;
                    if(!Command3Empty) begin
                        Fifo3ReadState  <= `AXIREADTRANS   ;
                    end
                    else begin
                        Fifo3ReadState  <= `AXIREADFIFO    ;
                    end
                end
                default: begin
                    Fifo3ReadSize   <= 3'b0                ;
                    Fifo3ReadLen    <= 8'b0                ;
                    Fifo3ReadId     <= 4'b0                ;
                    Fifo3ReadState  <= `AXIREADIDLE        ;
                    Fifo3ReadData   <= {AXIWIDTH{1'b0}}    ;
                    AxiSlipTran     <= 1'b0                ;
                    TransCnt        <= 4'b0                ;
                    FifoDataTemp    <= {AXIWIDTH{1'b0}}    ;
                end
            endcase
         end 
    end

    assign  RidSlave    = RvalidSlave   ? Fifo3ReadId : 4'b0 ;
    assign  RrespSlave  = (RlastSlave)  ?  2'b1 : 2'b00;
    assign  RvalidSlave = (Fifo3ReadLen > 0) && AxiSlipTran ;  
    assign  RdataSlave  = RvalidSlave   ? Fifo3ReadData : {AXIWIDTH{1'b0}} ;
    assign  RlastSlave  = (Fifo3ReadLen == 1);


    assign ReadFifo3ReadEn = (Fifo3ReadState == `AXIREADFIFO) ;


    wire  [ADDRWIDTH + 4 + 8 + 3 + 2 + 1 -1 :0        ] Fifo1ReadData ;
    wire                                                Fifo1ReadEn   ;
    wire  [AXIWIDTH + (AXIWIDTH/8)-1 : 0              ] Fifo2ReadData ;
    wire                                                Fifo2ReadEn   ;
    wire  [AXIWIDTH-1 : 0                             ] Fifo3WriteData;
    wire                                                Fifo3WriteEn  ;


    //读写请求 + 读写ID + 地址 + 突发传输长度 + 突发size + 突发类型
    NsyncFifo#(
        .WIDTH      ( ADDRWIDTH + 4 + 8 + 3 + 2 + 1        ), //上面说AXI的数据宽度不支持自定义，主要是此处的FIFO的宽度
        .DEPTH      ( 16'd4                                ),
        .WRFAST     ( `FALSE                               ),
        .RDFAST     ( `TURE                                )
    )CommandU1(
        .wr_clk      ( AxiClk                              ),
        .wr_reset_n  ( AxiRest                             ),
        .wr_en       ( InFifo1En                           ),
        .wr_data     ( {InFifo1WriteOrRead                 ,
                       InFifo1ReadId                       ,
                       InFifo1Addr                         ,
                       InFifo1WriteLen                     ,
                       InFifo1Size                         ,
                       InFifo1Burst                       }),
        .full      ( Command1Full                         ),
        .afull     (                                      ),
        .rd_clk    ( SdramClk                             ),
        .rd_reset_n( SdramRest                            ),
        .rd_en     ( Fifo1ReadEn                          ),
        .empty     ( Command1Empty                        ),
        .aempty    (                                      ),
        .rd_data   ( Fifo1ReadData                        )
    );

    //写数据 + 数据的掩码
    NsyncFifo#(
        .WIDTH      ( AXIWIDTH + (AXIWIDTH/8) ),
        .DEPTH      ( 16'd8                   ),
        .WRFAST     ( `FALSE                  ),
        .RDFAST     ( `TURE                   )
    )CommandU2(
        .wr_clk   ( AxiClk                  ),
        .wr_reset_n  ( AxiRest                 ),
        .wr_en    ( InFifo2En               ),
        .wr_data  ( {WdataSlave              ,//这里不对还得改
                       WstrbSlave            }),
        .full   ( Command2Full            ),
        .afull   (                         ),
        .rd_clk    ( SdramClk                ),
        .rd_reset_n   ( SdramRest               ),
        .rd_en     ( Fifo2ReadEn             ),
        
        .empty  ( Command2Empty           ),
        .aempty  (                         ),
        .rd_data   ( Fifo2ReadData           )
    );

    //是否是信息头信号 + 读数据
    /***************************************\
    信息头：
        31-------15 14---------12 11--------4 3------0
         reserve        size           len        id
    \***************************************/
    NsyncFifo#(
        .WIDTH      ( AXIWIDTH         ),
        .DEPTH      ( 16'd4            ),
        .WRFAST     ( `FALSE           ),
        .RDFAST     ( `TURE            )
    )CommandU3(
        .wr_clk   ( SdramClk         ),
        .wr_reset_n  ( SdramRest        ),
        .wr_en    ( Fifo3WriteEn     ),
        .wr_data  ( Fifo3WriteData   ),
        .full   ( Command3Full     ),
        .afull   (                  ),
        .rd_clk    ( AxiClk           ),
        .rd_reset_n   ( AxiRest          ),
        .rd_en     ( ReadFifo3ReadEn  ),
        
        .empty  ( Command3Empty    ),
        .aempty  (                  ),
        .rd_data   ( ReadFifo3Data    )
    );


    reg   [7:0                  ]  SdramState      ;
    reg   [ADDRWIDTH-1:0        ]  SdramTempAddr   ;
    reg   [4-1:0                ]  SdramTempID     ;
    reg   [8+3-1:0              ]  SdramTempLen    ;
    reg   [3-1:0                ]  SdramTempSize   ;
    reg   [2-1:0                ]  SdramTempType   ;
    reg                            SdramMRSAbleOut ;
    reg   [$clog2(SDRAMLINE)-1:0]  SdramMRSDataOut ;
    reg   [$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1)-1:0]  SdramRWNumber   ;
    reg                            SdramReadChannl ;
    reg                            SdramWriteChannl;

    wire                           RorWReqAccept   ;
    wire                           TransfFinish    ;

    wire [3+$clog2(SDRAMCLUM-1)-1 : 0] SelectNumber ;
    wire [8+3-1:0                  ] BurstLenByte ;
    assign BurstLenByte = (Fifo1ReadData[3+2-1:2] == 3'b000) ? {3'b0,Fifo1ReadData[8+3+2-1:3+2]     } : 
                          (Fifo1ReadData[3+2-1:2] == 3'b001) ? {2'b0,Fifo1ReadData[8+3+2-1:3+2],1'b0} : 
                          (Fifo1ReadData[3+2-1:2] == 3'b010) ? {1'b0,Fifo1ReadData[8+3+2-1:3+2],2'b0} : 
                          (Fifo1ReadData[3+2-1:2] == 3'b011) ? {     Fifo1ReadData[8+3+2-1:3+2],3'b0} : {$clog2(SDRAMCLUM-1)+3{1'b0}}; 

    assign SelectNumber = {3'b0,SdramTempAddr[$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1)-1 : $clog2((SDRAMWIDTH/8)-1)]} + SdramTempLen ;

    wire                             Selectline  ;
    assign Selectline   = (SelectNumber[$clog2(SDRAMCLUM-1)+3-1 : $clog2(SDRAMCLUM-1)] == 3'b0) ? `TURE : `FALSE ; //也就是说burst没有跨行
    wire [$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1)-1 : 0]   FinalNumber ;
    assign FinalNumber  = Selectline ? (SdramTempLen[9:0]) : ({$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b1}}-SdramTempAddr[$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1)-1:0]) ;

    always @(posedge SdramClk) begin
        if(!SdramRest)begin
            SdramState     <= `SDRAMIDLE       ;
            SdramTempAddr  <= {ADDRWIDTH{1'b0}};
            SdramTempID    <= 4'b0             ;
            SdramTempLen   <= 11'b0             ;
            SdramTempSize  <= 3'b0             ;
            SdramTempType  <= 2'b0             ;
            SdramMRSAbleOut<= `FALSE           ;
            SdramMRSDataOut<= {$clog2(SDRAMLINE-1){1'b0}} ;
            SdramRWNumber  <= {$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b0}} ;
            SdramReadChannl<= 1'b0             ;
            SdramWriteChannl<= 1'b0            ;
        end
        else begin
            case (SdramState)
                `SDRAMIDLE : begin
                    SdramTempAddr  <= {ADDRWIDTH{1'b0}};
                    SdramTempID    <= 4'b0             ;
                    SdramTempLen   <= 11'b0            ;
                    SdramTempSize  <= 3'b0             ;
                    SdramTempType  <= 2'b0             ;
                    SdramMRSAbleOut<= `FALSE           ;
                    SdramMRSDataOut<= {$clog2(SDRAMLINE-1){1'b0}} ;
                    SdramRWNumber  <= {$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b0}} ;
                    SdramReadChannl<= 1'b0             ;
                    SdramWriteChannl<= 1'b0            ;
                    if(!Command1Empty) begin
                        SdramState <= `SDRAMREADF1 ;
                    end
                    else begin
                        SdramState <= `SDRAMIDLE   ;
                    end
                end 
                `SDRAMREADF1 : begin
                    SdramState     <= `SDRAMMANGE                                         ;
                    SdramTempID    <= Fifo1ReadData[ADDRWIDTH+4+8+3+2-1 : ADDRWIDTH+8+3+2];
                    SdramTempAddr  <= Fifo1ReadData[ADDRWIDTH+8+3+2-1   : 8+3+2          ];
                    SdramTempLen   <= BurstLenByte                                        ; //len 也是 byte
                    SdramTempSize  <= Fifo1ReadData[3+2-1               : 2              ];
                    SdramTempType  <= Fifo1ReadData[2-1                 : 0              ];
                    SdramMRSAbleOut<= `FALSE                                              ;
                    SdramMRSDataOut<= {$clog2(SDRAMLINE-1){1'b0}}                           ;
                    SdramRWNumber  <= {$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b0}}                           ;
                    if(Fifo1ReadData[ADDRWIDTH+4+8+3+2+1-1 : ADDRWIDTH+4+8+3+2]) begin
                        SdramReadChannl <= 1'b1             ;
                    end
                    else begin
                        SdramWriteChannl<= 1'b1             ;
                    end
                end
                `SDRAMMANGE : begin 
                    if(SdramTempLen == 0) begin
                        SdramState     <= `SDRAMIDLE       ;
                        SdramTempAddr  <= {ADDRWIDTH{1'b0}};
                        SdramTempID    <= 4'b0             ;
                        SdramTempLen   <= 11'b0            ;
                        SdramTempSize  <= 3'b0             ;
                        SdramTempType  <= 2'b0             ;
                        SdramMRSAbleOut<= `FALSE           ;
                        SdramMRSDataOut<= {$clog2(SDRAMLINE-1){1'b0}} ;
                        SdramRWNumber  <= {$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b0}} ;
                        SdramWriteChannl<= 1'b0            ;
                        SdramReadChannl<= 1'b0             ;
                    end
                    else begin
                        SdramState     <= `SDRAMCERTIN     ;
                        SdramTempID    <= SdramTempID      ;
                        SdramTempAddr  <= SdramTempAddr    ;
                        SdramTempLen   <= SdramTempLen     ;
                        SdramTempSize  <= SdramTempSize    ;
                        SdramTempType  <= SdramTempType    ;
                        SdramReadChannl<= SdramReadChannl  ;
                        SdramWriteChannl<=SdramWriteChannl ;
                        SdramMRSAbleOut <= `TURE           ;
                        SdramMRSDataOut <=  (FinalNumber[2+$clog2((SDRAMWIDTH/8)-1):$clog2((SDRAMWIDTH/8)-1)] == 3'b000) ? {{$clog2(SDRAMLINE-1)-7{1'b0}},3'b010,1'b0,3'b011}  :
                                            (FinalNumber[1+$clog2((SDRAMWIDTH/8)-1):$clog2((SDRAMWIDTH/8)-1)] == 2'b00)  ? {{$clog2(SDRAMLINE-1)-7{1'b0}},3'b010,1'b0,3'b010} :
                                            (FinalNumber[$clog2((SDRAMWIDTH/8)-1):$clog2((SDRAMWIDTH/8)-1)] == 1'b0)   ? {{$clog2(SDRAMLINE-1)-7{1'b0}},3'b010,1'b0,3'b001} :
                                            {{$clog2(SDRAMLINE-1)-7{1'b0}},3'b010,1'b0,3'b000};
                        SdramRWNumber   <= FinalNumber     ;
                    end
                end 
                `SDRAMCERTIN : begin
                    SdramTempID    <= SdramTempID      ;
                    SdramTempAddr  <= SdramTempAddr    ;
                    SdramTempLen   <= SdramTempLen     ;
                    SdramTempSize  <= SdramTempSize    ;
                    SdramTempType  <= SdramTempType    ;
                    SdramMRSAbleOut<= SdramMRSAbleOut  ;
                    SdramMRSDataOut<= SdramMRSDataOut  ;
                    SdramRWNumber  <= SdramRWNumber    ;
                    SdramReadChannl<= SdramReadChannl  ;
                    SdramWriteChannl<=SdramWriteChannl ;
                    if(RorWReqAccept) begin
                        SdramState     <= `SDRAMTFINISH    ;
                    end
                    else begin
                        SdramState     <= `SDRAMCERTIN     ;
                    end
                end
                `SDRAMTFINISH : begin
                    SdramTempSize  <= SdramTempSize    ;
                    SdramTempType  <= SdramTempType    ;
                    SdramMRSAbleOut<= SdramMRSAbleOut  ;
                    SdramMRSDataOut<= SdramMRSDataOut  ;
                    SdramRWNumber  <= SdramRWNumber    ;
                    SdramReadChannl<= 1'b0             ;
                    SdramWriteChannl<=1'b0             ;
                    if(TransfFinish) begin
                        SdramState     <= `SDRAMMANGE      ;
                        SdramTempID    <= SdramTempID      ;
                        SdramTempAddr  <= SdramTempAddr  +  {{ADDRWIDTH-$clog2(SDRAMCLUM-1)-$clog2((SDRAMWIDTH/8)-1){1'b0}},SdramRWNumber} ;
                        SdramTempLen   <= SdramTempLen   -  SdramRWNumber ;
                    end
                    else begin
                        SdramState     <= `SDRAMTFINISH    ;
                        SdramTempID    <= SdramTempID      ;
                        SdramTempAddr  <= SdramTempAddr    ;
                        SdramTempLen   <= SdramTempLen     ;
                    end
                end
                default: begin
                    SdramState     <= `SDRAMIDLE       ;
                    SdramTempAddr  <= {ADDRWIDTH{1'b0}};
                    SdramTempID    <= 4'b0             ;
                    SdramTempLen   <= 11'b0            ;
                    SdramTempSize  <= 3'b0             ;
                    SdramTempType  <= 2'b0             ;
                    SdramMRSAbleOut<= `FALSE           ;
                    SdramMRSDataOut<= {$clog2(SDRAMLINE-1){1'b0}} ;
                    SdramRWNumber  <= {$clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1){1'b0}} ;
                    SdramWriteChannl<= 1'b0            ;
                    SdramReadChannl<= 1'b0             ;
                end
            endcase
        end
    end

wire                                                 ToScoreReadChannl ;
wire                                                 ToScoreWriteChannl;
wire [$clog2(SDRAMLINE-1) + $clog2(SDRAMCLUM-1)+$clog2((SDRAMWIDTH/8)-1)+2-1:$clog2((SDRAMWIDTH/8)-1)]   ToScoreRorWaddr   ;
wire [$clog2(SDRAMCLUM-1) + $clog2((SDRAMWIDTH/8)-1)-1:0]                                                ToScoreRorWNumber ;
wire                                                   ToScoreMRSAble    ;
wire [$clog2(SDRAMLINE-1)-1:0]                         ToScoreMRSData    ;

assign ToScoreReadChannl  = SdramReadChannl ;
assign ToScoreWriteChannl = SdramWriteChannl;
assign ToScoreRorWaddr    = SdramTempAddr[$clog2(SDRAMLINE) + $clog2(SDRAMCLUM)+$clog2((SDRAMWIDTH/8)-1)+2-1:$clog2((SDRAMWIDTH/8)-1)];
assign ToScoreRorWNumber  = SdramRWNumber   ;
assign ToScoreMRSAble     = SdramMRSAbleOut ;
assign ToScoreMRSData     = SdramMRSDataOut ;


assign Fifo1ReadEn = (SdramState == `SDRAMREADF1) ;


parameter NUMBERBYTEAXI   = (AXIWIDTH == 32) ? 4'd4 :
                            (AXIWIDTH == 64) ? 4'd8 : 4'd0;

parameter NUMBERBYTESDRAM = (SDRAMWIDTH == 32) ? 4'd4 :
                            (SDRAMWIDTH == 16) ? 4'd2 :
                            (SDRAMWIDTH == 16) ? 4'd1 : 4'd0;

wire                                   SCoreAcceptAble;
reg [(AXIWIDTH/8)+(SDRAMWIDTH/8)-1:0]  SCoreAccMask ;                 
reg [AXIWIDTH+SDRAMWIDTH-1 : 0      ]  ToCoreData   ; 
reg [3:0                            ]  TfCnt        ;
reg                                    OutToCoreAble;

assign Fifo2ReadEn = (TfCnt == 4'b0) && SCoreAcceptAble && ~Command2Empty ;

always @(posedge Clk) begin
    if(!SdramRest) begin
        ToCoreData   <= {AXIWIDTH+SDRAMWIDTH{1'b0}}        ;
        SCoreAccMask <= {(AXIWIDTH/8)+(SDRAMWIDTH/8){1'b0}};
        TfCnt        <= 4'b0                               ;
        OutToCoreAble<= 1'b0                               ;
    end
    else begin
        if(TfCnt == 4'b0) begin 
            ToCoreData   <= ~Command2Empty ? {Fifo2ReadData[AXIWIDTH-1 : 0],{SDRAMWIDTH{1'b0}}} : {AXIWIDTH+SDRAMWIDTH{1'b0}} ;
            SCoreAccMask <= ~Command2Empty ? {Fifo2ReadData[AXIWIDTH + (AXIWIDTH/8) -1 : AXIWIDTH],{(SDRAMWIDTH/8){1'b0}}} : {(AXIWIDTH/8)+(SDRAMWIDTH/8){1'b0}};
            TfCnt        <= ~Command2Empty ? NUMBERBYTEAXI : 4'b0 ; 
            OutToCoreAble<= 1'b0                                ; 
        end 
        else begin
            TfCnt        <= SCoreAcceptAble ? (TfCnt - NUMBERBYTESDRAM)       : TfCnt      ;
            ToCoreData   <= SCoreAcceptAble ? ToCoreData   >> SDRAMWIDTH     : ToCoreData  ;
            SCoreAccMask <= SCoreAcceptAble ? SCoreAccMask >> (SDRAMWIDTH/8) : SCoreAccMask;
            OutToCoreAble<= SCoreAcceptAble ? `TURE                          : `FALSE      ;
        end    
    end
end


reg [AXIWIDTH+SDRAMWIDTH-1 : 0]  ToFifoData ;
reg [3:0                ]  ReadCnt      ;
reg                        ReadInAble   ;

wire [SDRAMWIDTH-1:0    ]  InToTemp     ;
wire                       InToTempAble ;

always @(posedge Clk) begin
    if(!SdramRest) begin
        ToFifoData <= {AXIWIDTH+SDRAMWIDTH{1'b0}} ;
        ReadCnt    <= 4'b0             ;
        ReadInAble <= 1'b0             ;
    end
    else begin
        if(ReadCnt == NUMBERBYTEAXI) begin
            ToFifoData <= {AXIWIDTH+SDRAMWIDTH{1'b0}} ;
            ReadCnt    <= 4'b0             ;
            ReadInAble <= 1'b0             ;
        end
        else begin
            ToFifoData <= InToTempAble ? ({ToFifoData[AXIWIDTH+SDRAMWIDTH-1:SDRAMWIDTH],InToTemp} << SDRAMWIDTH) : ToFifoData ;
            ReadCnt    <= InToTempAble ? (ReadCnt + NUMBERBYTESDRAM)           : ReadCnt    ;
            ReadInAble <= InToTempAble ? `TURE                                 : `FALSE     ;
        end
    end
end

assign Fifo3WriteEn    = ReadInAble ;
assign Fifo3WriteData  = ToFifoData[AXIWIDTH+SDRAMWIDTH-1:SDRAMWIDTH] ;

SdramCore#(
    .SDRAMMHZ        ( SDRAMMHZ               ),
    .SDRAMLINE       ( SDRAMLINE              ),
    .SDRAMCLUM       ( SDRAMCLUM              ),
    .SDRAMWIDTH      ( SDRAMWIDTH             ),
    .FIFODEPTH       ( FIFODEPTH              )
)u_SdramCore(
    .Clk             ( SdramClk               ),
    .Rest            ( SdramRest              ),
    .ReadAble        ( ToScoreReadChannl      ),
    .WriteAble       ( ToScoreWriteChannl     ),
    .AcceptDone      ( RorWReqAccept          ),
    .MRSAble         ( ToScoreMRSAble         ),
    .MRSData         ( ToScoreMRSData         ),
    .RorWAddr        ( ToScoreRorWaddr        ),
    .RorWNumber      ( ToScoreRorWNumber[$clog2(SDRAMCLUM-1) + $clog2((SDRAMWIDTH/8)-1)-1 : $clog2((SDRAMWIDTH/8)-1)] ),
    .RorWFinish      ( TransfFinish           ),
    .CtrlCanAccept   ( Command3Full           ),
    .OutDataValid    ( InToTempAble           ),
    .ReadData        ( InToTemp               ),
    .WriteCanAccept  ( SCoreAcceptAble        ),
    .InDataValid     ( OutToCoreAble          ),
    .WriteData       ( {ToCoreData[SDRAMWIDTH-1:0],
                       SCoreAccMask[(SDRAMWIDTH/8)-1:0]}),
    .ChipDin         ( Dq                     ),
    .ChipDout        ( Dq                     ),
    .ChipAddr        ( Addr                   ),
    .ChipBank        ( Bank                   ),
    .ChipClk         ( Clk                    ),
    .ChipCke         ( Cke                    ),
    .ChipCs_n        ( Cs_n                   ),
    .ChipRas_n       ( Ras_n                  ),
    .ChipCas_n       ( Cas_n                  ),
    .ChipWe_n        ( We_n                   ),
    .ChipDqm         ( Dqm                    )
);


endmodule
