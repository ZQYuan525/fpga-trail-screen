`timescale 1ns/1ps
// Six physical digits. Error display preempts normal PIC/VOL/PRD pages.
// Low power: each digit is lit for the first SEG_ON_CYCLES of its scan slot,
// and the whole display goes dark after IDLE_PAGES page periods without a key
// press, menu or error. Any of those lights it again.
module player_panel #(
    parameter integer CLK_HZ=50_000_000,SCAN_CYCLES=CLK_HZ/1000,PAGE_CYCLES=CLK_HZ*2,
    parameter integer SEG_ON_CYCLES=SCAN_CYCLES/4,IDLE_PAGES=30
)(
    input wire clk,rst,
    input wire [3:0] status,image,
    input wire [2:0] volume,selection,
    input wire [1:0] period,
    input wire menu,activity,
    output reg [5:0] seg_sel,output reg [7:0] seg_data
);
    reg [$clog2(PAGE_CYCLES)-1:0] page_ticks;
    reg [15:0] scan_ticks;
    reg [2:0] digit;
    reg [1:0] page;
    reg [$clog2(IDLE_PAGES+1)-1:0] idle_pages;
    wire awake=activity || menu || status>=10;
    wire [1:0] shown=menu && selection==6?1:menu && selection==4?2:page;
    reg [7:0] c;
    reg [7:0] decoded;
    always @(*) begin
        c=" ";
        if(status>=10) begin
            case(digit)
                5:c="E";4:c="r";3:c="r";
                0:c=status==10?"A":status==11?"b":status==12?"C":status==13?"d":status==14?"E":"F";
            endcase
        end else case(shown)
            0:case(digit) 5:c="P";4:c="I";3:c="C";0:c=image==0?"-":"0"+image;endcase
            1:case(digit)
                5:c="V";4:c="O";3:c="L";2:c=volume==4?"1":" ";
                1:c=volume==1?"2":volume==2?"5":volume==3?"7":"0";
                0:c=volume==1 || volume==3?"5":"0";
            endcase
            2:case(digit)
                5:c="P";4:c="r";3:c="d";1:c=period==3?"1":"0";
                0:c=period==0?"1":period==1?"3":period==2?"5":"0";
            endcase
        endcase
        case(c)
            "0":decoded=8'hc0;"1":decoded=8'hf9;"2":decoded=8'ha4;"3":decoded=8'hb0;
            "4":decoded=8'h99;"5":decoded=8'h92;"6":decoded=8'h82;"7":decoded=8'hf8;
            "8":decoded=8'h80;"9":decoded=8'h90;"A":decoded=8'h88;"b":decoded=8'h83;
            "C":decoded=8'hc6;"d":decoded=8'ha1;"E":decoded=8'h86;"F":decoded=8'h8e;
            "P":decoded=8'h8c;"I":decoded=8'hf9;"V":decoded=8'hc1;"O":decoded=8'hc0;
            "L":decoded=8'hc7;"r":decoded=8'haf;"-":decoded=8'hbf;default:decoded=8'hff;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin page_ticks<=0;scan_ticks<=0;digit<=0;page<=0;idle_pages<=0;seg_sel<=6'b111111;seg_data<=8'hff;end
        else begin
            if(page_ticks==PAGE_CYCLES-1) begin page_ticks<=0;page<=page==2?0:page+1'b1;end
            else page_ticks<=page_ticks+1'b1;
            if(awake) idle_pages<=0;
            else if(page_ticks==PAGE_CYCLES-1 && idle_pages!=IDLE_PAGES) idle_pages<=idle_pages+1'b1;
            if(scan_ticks==SCAN_CYCLES-1) begin scan_ticks<=0;digit<=digit==5?0:digit+1'b1;end
            else scan_ticks<=scan_ticks+1'b1;
            // A blank clock at each digit handover avoids displaying the old
            // segment pattern under a newly selected digit.
            seg_sel<=scan_ticks==0 || scan_ticks>SEG_ON_CYCLES || idle_pages==IDLE_PAGES?6'b111111:~(6'b100000>>digit);
            seg_data<=decoded;
        end
    end
endmodule
