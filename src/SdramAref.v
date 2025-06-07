/*********************************************************************
                                                              
    SDRAM自刷新模块                
    描述: SDRAM自刷新
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.13  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`timescale 1ns/1ps
`include "define.v"
module SdramAref #(
    parameter     SDRAMMHZ    =               100      ,
    parameter     SDRAMLINE   =               2048   
) (
    input       wire                           Clk         ,
    input       wire                           Rest        ,

    input       wire                           SdramGetS   ,

    output      wire                           ArefReq     , //提前16个周期先提前占用状态
    output      wire   [3:0      ]             ArefCmd     ,
    output      wire   [$clog2(SDRAMLINE)-1:0] ArefMode    ,
    output      wire                           ArefDone             
);

    parameter NSPRESEC  =  $ceil (1000     / SDRAMMHZ) ;
    parameter CYCNUMREF =  $floor(64000 / NSPRESEC) ; //捡了三个0
    parameter CYCNUMRFC =  $ceil (70       / NSPRESEC) ;
    parameter CYCNUMRP  =  $ceil (20       / NSPRESEC) ;

    reg [3:0]  ArefState      ;
    reg [3:0]  ArefCmgReg     ;
    reg [23:0] ArefCnt        ;

    always @(posedge Clk) begin
        if(!Rest) begin
            ArefState      <= `SDAREFIDLE ;
            ArefCmgReg     <= `NOPC       ;
            ArefCnt        <= 24'd0       ;
        end
        else begin
            case (ArefState)
                `SDAREFIDLE: begin
                    ArefCmgReg     <= `NOPC       ;
                    if(ArefCnt >= CYCNUMREF)begin
                        ArefState  <= `SDAREFPREC ;
                        ArefCnt    <= 24'd0       ;
                    end
                    else if(SdramGetS) begin 
                        ArefState  <= `SDAREFPREC ;
                        ArefCnt    <= 24'd0       ;
                    end
                    else begin
                        ArefState  <= `SDAREFIDLE ;
                        ArefCnt    <= ArefCnt + 1 ;
                    end

                end
                `SDAREFPREC : begin
                    if(ArefCnt == 0)begin
                        ArefState      <= `SDAREFPREC ;
                        ArefCmgReg     <= `PRECHAGE   ;
                        ArefCnt        <= ArefCnt + 1 ;
                    end
                    else begin
                        ArefCmgReg     <= `NOPC       ;
                        if(ArefCnt == CYCNUMRP) begin
                            ArefState      <= `SDAREFAREF ;
                            ArefCnt        <= 24'd0       ;
                        end
                        else begin
                            ArefState      <= `SDAREFPREC ;
                            ArefCnt        <= ArefCnt + 1 ;
                        end
                    end
                end
                `SDAREFAREF : begin
                    if(ArefCnt == 0) begin
                        ArefState      <= `SDAREFAREF ;
                        ArefCmgReg     <= `AUTOREF    ;
                        ArefCnt        <= ArefCnt + 1 ;
                    end
                    else begin
                        if(ArefCnt == CYCNUMRFC) begin
                            ArefState      <= `SDAREFIDLE ;
                            ArefCmgReg     <= `NOPC       ;
                            ArefCnt        <= 24'd0       ;
                        end 
                        else begin
                            ArefState      <= `SDAREFAREF ;
                            ArefCmgReg     <= `NOPC       ;
                            ArefCnt        <= ArefCnt + 1 ;
                        end 
                    end
                end
                default: begin
                    ArefState      <= `SDAREFIDLE ;
                    ArefCmgReg     <= `NOPC       ;
                    ArefCnt        <= 24'd0       ;
                end
            endcase
        end
    end
    
    assign ArefReq     = (ArefState == `SDAREFIDLE) && (ArefCnt >= CYCNUMREF - 16);
    assign ArefCmd     = ArefCmgReg    ;
    assign ArefDone    = (ArefState == `SDAREFAREF) && (ArefCnt == CYCNUMRFC)     ;
    assign ArefMode    = ((ArefState == `SDAREFPREC) && (ArefCnt == 0))? {{$clog2(SDRAMLINE)-11{1'b0}},1'b1,10'b0} : {$clog2(SDRAMLINE){1'b0}};

endmodule
