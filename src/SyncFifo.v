/*********************************************************************
                                                              
    同步FIFO                
    描述: 同步FIFO
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.7  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`timescale 1ns/1ps
module SyncFifo #(
    parameter WIDTH = 8                       ,
    parameter DEPTH = 4                       
) (
    input      wire                           Clk          ,
    input      wire                           Rest         ,
    
    input      wire                           WriteEn      ,
    input      wire   [WIDTH-1:0]             WriteData    ,
    output     wire                           FifoFullSign ,
    output     wire                           FifoEmptySign,
    input      wire                           ReadEn       ,
    output     wire   [WIDTH-1:0]             ReadData     
);

    //this fifo is fast read no lazy read
    //and for full sign and empty sign same
    parameter DEPTHAW = (DEPTH == 4)   ? 2 :
                        (DEPTH == 8)   ? 3 :
                        (DEPTH == 16)  ? 4 :
                        (DEPTH == 32)  ? 5 :
                        (DEPTH == 64)  ? 6 :
                        (DEPTH == 128) ? 7 :
                        (DEPTH == 256) ? 8 : 0;

    reg [WIDTH-1  : 0] Mem [DEPTH-1 : 0] ;
    reg [DEPTHAW-1 : 0] ReadPtr           ;
    reg [DEPTHAW-1 : 0] WritePtr          ;

    /************Fifo write logic*************/
    always @(posedge Clk) begin
        if(!Rest) begin
            WritePtr <= {DEPTHAW{1'b0}};
        end
        else begin
            if(WriteEn && !FifoFullSign)
                WritePtr <= WritePtr + 1'b1 ;
            else 
                WritePtr <= WritePtr        ;
        end
    end

    reg       FullReg   ; 
    always @(posedge Clk) begin
        if(!Rest)
            FullReg <= 1'b0 ;
        else 
            FullReg <= (((WritePtr - ReadPtr) == {{(DEPTHAW-1){1'b1}},1'b0}) & ~ReadEn & WriteEn) ? 1'b1 :
                       (((WritePtr - ReadPtr) == {DEPTHAW{1'b1}}) & ReadEn & ~WriteEn)            ? 1'b0 :
                       FullReg ;
    end

    /************Fifo read logic**************/

    always @(posedge Clk) begin
        if(!Rest) begin
            ReadPtr <= {DEPTHAW{1'b0}};
        end
        else begin
            if(ReadEn && !FifoEmptySign)
                ReadPtr <= ReadPtr + 1'b1 ;
            else 
                ReadPtr <= ReadPtr        ;
        end 
    end

    reg       EmptyReg    ;
    always @(posedge Clk) begin
        if(!Rest) 
            EmptyReg <= 1'b1 ;
        else 
            EmptyReg <= (((WritePtr - ReadPtr) == {{(DEPTHAW-1){1'b0}},1'b1}) & ReadEn & ~WriteEn) ? 1'b1 :
                        (((WritePtr - ReadPtr) == {DEPTHAW{1'b0}}) & ~ReadEn & WriteEn)            ? 1'b0 :
                        EmptyReg;
    end

    always @(posedge Clk) begin
        if(WriteEn)
            Mem[WritePtr] <= WriteData ;
    end

    assign ReadData = Mem[ReadPtr] ; //速读，速空，速满

    assign FifoFullSign = FullReg ;
    assign FifoEmptySign = EmptyReg ;

    
endmodule
