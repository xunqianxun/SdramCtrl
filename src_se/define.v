/*********************************************************************
                                                              
    define file              
    描述: define
    作者: 李国旗 asdcdqwe@163.com  
    日期: 2025.5.30  
    版权所有：一生一芯 
    Copyright (C) ysyx.org       
                                                   
*******************************************************************/
`define TURE         1 
`define FALSE        0

`define AXIWIDTH     31:0
`define AXIADDRW     31:0
`define AXIID        3:0
`define AXILEN       7:0
`define AXISIZE      2:0 //不支持非对齐,只能是1248
`define AXIBURST     1:0
`define AXICACHE     3:0
`define AXISTRB      3:0
`define AXIRESP      1:0
`define AXIPORT      2:0


`define AXIIDLE       8'b00000000 
`define AXIREAD       8'b00000001
`define AXIWRITE      8'b00000010
`define AXIWRITEBURST 8'b00000011
`define AXIWRESP      8'b00000111
`define AXIREADBURST  8'b00001111 
`define AXIBRESP      8'b00011111
`define AXIREADING    8'b00111111 
`define AXIWRITEING   8'b01111111 
`define AXIWRITEGET   8'b11111111 


`define RBURSTIDLE    4'b0001 
`define RBURSTREADIN  4'b0011 
`define RBURSTREADOU  4'b0111 
`define RBURSTTRANS   4'b1111 

`define WBRUSTIDLE    4'b0001
`define WBURSTWRITEIN 4'b0011
`define WBURSTWRITE   4'b0111  


`define AXIREADIDLE  4'b0001 
`define AXIREADTRANS 4'b0011
`define AXIREADFIFO  4'b0111 


//SDRAM COMMANDS

//      command type   CS-RAS-CAS-WE

`define NOPC           4'b0111 
`define PRECHAGE       4'b0010 
`define AUTOREF        4'b0001 
`define MODEREGSET     4'b0000
`define ROWACTIVE      4'b0011 
`define READC          4'b0101 
`define WRITEC         4'b0100  
//SDRAM Core State 
`define SCOREINIT     8'b00000001 
`define SCOREIDLE     8'b00000011
`define SCOREANYLZ    8'b00000111
`define SCOREPCHGE    8'b00001111 
`define SCOREREAD     8'b00011111 
`define SCOREWRITE    8'b00111111 
`define SCOREAREF     8'b01111111 
`define SCOREACTIVE   8'b11111111


`define SDRAMIDLE    8'b00000001 
`define SDRAMREADF1  8'b00000011 
`define SDRAMMANGE   8'b00000111 
//`define SDRAMWRITE   8'b00001111
//`define SDRAMINREAD  8'b00011111 
`define SDRAMCERTIN  8'b00111111 
`define SDRAMTFINISH 8'b01111111 

//SDRAM Init State 
`define SDINITSTABLE  4'b0000 
`define SDINITIDLE    4'b0001 
`define SDINITPRECH   4'b0011 
`define SDINITAPREF   4'b0111
`define SDINITMRS     4'b1111

//SDRAM aref state 
`define SDAREFIDLE    4'b0001 
`define SDAREFPREC    4'b0011 
`define SDAREFAREF    4'b0111 



