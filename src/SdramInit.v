/*********************************************************************
                                                              
    SDRAM初始化流程                
    描述: SDRAN初始化
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.12  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "define.v"
module SdramInit #(
    parameter  SDRAMMHZ      =   100       ,
    parameter  SDRAMLINE     =   2048                            
) (
    input       wire                             Clk           ,
    input       wire                             Rest          ,

    input       wire                             ReInit        ,

    output      wire    [3:0 ]                   SdramCmd      ,
    output      wire    [$clog2(SDRAMLINE)-1:0]  SdramMode     ,
    output      wire                             SdramInitDone 
);

    parameter NSPRESEC  =  $ceil(1000 / SDRAMMHZ) ;
    parameter CYCNUMST  =  $ceil(200  / NSPRESEC) ; 
    parameter CYCNUMRP  =  $ceil(20   / NSPRESEC) ; 
    parameter CYCNUMRFC =  $ceil(70   / NSPRESEC) ;
    parameter SDRAMBURST=  3'b011                 ; //仅初始化的时候使用
    parameter SDRAMTYPE =  1'b0                   ;    

    reg  [3:0]                   SdramInitState ;
    reg  [3:0]                   SdramCmdReg    ;
    reg  [$clog2(SDRAMLINE)-1:0] SdramModeReg   ;
    reg  [7:0]                   CntDly         ;
    reg                          InitDone       ;
    always @(posedge Clk) begin
        if(!Rest) begin
            SdramInitState <= `SDINITSTABLE    ;
            SdramCmdReg    <= `NOPC            ;
            SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
            CntDly         <= 8'd0             ;
            InitDone       <= 1'b0             ;
        end
        else begin
            case (SdramInitState)
                `SDINITSTABLE: begin
                    SdramCmdReg   <= `NOPC      ;
                    SdramModeReg  <= {$clog2(SDRAMLINE){1'b0}}      ;
                    InitDone      <= 1'b0       ;
                    if(CntDly >= CYCNUMST)begin 
                        SdramInitState <= `SDINITPRECH ;
                        CntDly         <= 8'd0         ;
                    end 
                    else begin
                        SdramInitState <= `SDINITSTABLE;
                        CntDly         <= CntDly + 1   ;
                    end
                end
                `SDINITPRECH : begin
                    InitDone       <= 1'b0               ;
                    if(CntDly == 0)begin 
                        SdramInitState<= `SDINITPRECH    ;
                        SdramCmdReg   <= `PRECHAGE       ;
                        SdramModeReg  <= {{$clog2(SDRAMLINE)-11{1'b0}},1'b1,10'b0};
                        CntDly        <= CntDly + 1      ;
                    end 
                    else if((CntDly > 0) && (CntDly < CYCNUMRP)) begin
                        SdramInitState <= `SDINITPRECH   ;
                        SdramCmdReg    <= `NOPC          ;
                        SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                        CntDly         <= CntDly + 1     ;
                    end
                    else if(CntDly >= CYCNUMRP) begin
                        SdramInitState <= `SDINITAPREF   ;
                        SdramCmdReg    <= `NOPC          ;
                        SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                        CntDly         <= 8'd0           ;
                    end
                end
                `SDINITAPREF : begin
                    SdramModeReg       <= {$clog2(SDRAMLINE){1'b0}};
                    InitDone           <= 1'b0           ;
                    if((CntDly == 0) || (CntDly == CYCNUMRFC)) begin
                        SdramInitState <= `SDINITAPREF   ;
                        SdramCmdReg    <= `AUTOREF       ;
                        CntDly         <= CntDly + 1     ;
                    end
                    else if((CntDly > 0) && (CntDly != CYCNUMRFC) && (CntDly < (2 * CYCNUMRFC))) begin
                        SdramInitState <= `SDINITAPREF   ;
                        SdramCmdReg    <= `NOPC          ;
                        CntDly         <= CntDly + 1     ;
                    end 
                    else if(CntDly >= (2 * CYCNUMRFC)) begin
                        SdramInitState <= `SDINITMRS     ;
                        SdramCmdReg    <= `NOPC          ;
                        CntDly         <= 8'd0           ;
                    end
                end
                `SDINITMRS : begin
                    if(CntDly == 0) begin
                        SdramInitState <= `SDINITMRS     ;
                        SdramCmdReg    <= `MODEREGSET    ;
                        SdramModeReg   <= {{($clog2(SDRAMLINE)-7){1'b0}},3'b010,SDRAMTYPE,SDRAMBURST};
                        CntDly         <= CntDly + 1     ;
                        InitDone       <= 1'b0           ;
                    end
                    else if(CntDly != 0) begin
                        SdramInitState <= `SDINITIDLE    ;
                        SdramCmdReg    <= `NOPC          ;
                        SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                        CntDly         <= 8'd0           ;
                        InitDone       <= 1'b1           ;
                    end
                end
                `SDINITIDLE : begin
                    InitDone           <= 1'b0           ;
                    if(ReInit)begin
                        SdramInitState <= `SDINITSTABLE  ;
                        SdramCmdReg    <= `NOPC          ;
                        SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                        CntDly         <= 8'd0           ;
                    end
                    else begin
                        SdramInitState <= `SDINITIDLE    ;
                        SdramCmdReg    <= `NOPC          ;
                        SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                        CntDly         <= 8'd0           ;
                    end
                end
                default: begin
                    SdramInitState <= `SDINITSTABLE    ;
                    SdramCmdReg    <= `NOPC            ;
                    SdramModeReg   <= {$clog2(SDRAMLINE){1'b0}};
                    CntDly         <= 8'd0             ;
                    InitDone       <= 1'b0             ;
                end
            endcase

        end 
    end


    assign SdramCmd      = SdramCmdReg ;
    assign SdramMode     = SdramModeReg;
    assign SdramInitDone = InitDone    ;
    
endmodule
