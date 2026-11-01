`timescale 1ns/1ps
// Streaming two-row scaler. Coordinates align endpoints; Q16 step, Q8 weights.
// The source row order is preserved (writer separately handles BMP orientation).
module bilinear_scaler #(
    parameter OUT_WIDTH=640,OUT_HEIGHT=480,MAX_WIDTH=1280,MAX_HEIGHT=960
)(
    input wire clk,rst,start,abort_load,
    input wire [15:0] source_width,source_height,
    input wire in_valid,input wire [23:0] in_data,output wire in_ready,
    input wire in_done,in_error,
    output wire out_valid,output reg [23:0] out_data,input wire out_ready,
    output reg done,error,output wire idle
);
    localparam IDLE=0,CHECK=1,FILL=2,READ0=3,READ1=4,HORIZONTAL=5,VERTICAL=6,OUTPUT_PIXEL=7,FINISH=8,DIVIDE=9,
               START_H=10,WAIT_H=11,WAIT_V=12,ADVANCE=13,COORD0=14,COORD1=15;
    localparam AW=MAX_WIDTH>1?$clog2(MAX_WIDTH):1;
    localparam SW=$clog2(MAX_WIDTH+1),SH=$clog2(MAX_HEIGHT+1);
    localparam OW=OUT_WIDTH>1?$clog2(OUT_WIDTH):1,OH=OUT_HEIGHT>1?$clog2(OUT_HEIGHT):1;
    reg [3:0] state;
    reg [23:0] line0[0:(1<<AW)-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] line1[0:(1<<AW)-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [SW-1:0] input_x;
    reg [SH-1:0] loaded_rows;
    // Registered at start: keep the source-1 subtractors off the FILL/COORD paths.
    reg [SW-1:0] width_m1,width_m2;
    reg [SH-1:0] height_m1;
    reg row_last;
    reg [OW-1:0] output_x;
    reg [OH-1:0] output_y;
    reg [SW+15:0] xstep,xpos;
    reg [SH+15:0] ystep,ypos;
    reg [31:0] xdiv,ydiv,xquot,yquot;
    reg [15:0] xrem,yrem;
    reg [5:0] div_count;
    wire [16:0] xr={xrem,xdiv[31]},yr={yrem,ydiv[31]};
    wire xsub=xr>=(OUT_WIDTH>1?OUT_WIDTH-1:1),ysub=yr>=(OUT_HEIGHT>1?OUT_HEIGHT-1:1);
    reg source_done;
    reg [SW-1:0] x0,x1;
    reg [SH-1:0] y0,y1;
    reg [7:0] fx,fy;
    reg [23:0] p00,p01,p10,p11,h0,h1;
    reg [23:0] corner00,corner01,corner10,corner11;
    reg [7:0] weight_x,weight_y;
    wire [23:0] blend0,blend1;
    wire blend_valid0,blend_valid1;
    rgb_lerp lerp0(.clk(clk),.rst(rst),.enable(state==START_H || state==VERTICAL),
        .a(state==START_H?corner00:h0),.b(state==START_H?corner01:h1),.weight(state==START_H?weight_x:weight_y),
        .valid(blend_valid0),.result(blend0));
    rgb_lerp lerp1(.clk(clk),.rst(rst),.enable(state==START_H),.a(corner10),.b(corner11),.weight(weight_x),
        .valid(blend_valid1),.result(blend1));
    reg [23:0] bank0_left,bank1_left,bank0_q,bank1_q;
    wire [AW-1:0] read_address=state==READ0?x0[AW-1:0]:x1[AW-1:0];
    assign idle=state==IDLE;
    assign in_ready=state==FILL && !abort_load && !in_error;
    assign out_valid=state==OUTPUT_PIXEL && !abort_load && !in_error;
    // Synchronous bank reads infer RAM; no reset loop on pixel storage.
    always @(posedge clk) begin
        if(in_valid && in_ready) begin
            if(loaded_rows[0]) line1[input_x[AW-1:0]]<=in_data;else line0[input_x[AW-1:0]]<=in_data;
        end
        if(state==READ0 || state==READ1) begin bank0_q<=line0[read_address];bank1_q<=line1[read_address];end
        if(state==READ1) begin bank0_left<=bank0_q;bank1_left<=bank1_q;end
    end
    always @(*) begin
        p00=y0[0]?bank1_left:bank0_left;
        p01=y0[0]?bank1_q:bank0_q;
        p10=y1[0]?bank1_left:bank0_left;
        p11=y1[0]?bank1_q:bank0_q;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;loaded_rows<=0;input_x<=0;output_x<=0;output_y<=0;
            width_m1<=0;width_m2<=0;height_m1<=0;row_last<=0;
            xstep<=0;ystep<=0;xpos<=0;ypos<=0;source_done<=0;done<=0;error<=0;out_data<=0;h0<=0;h1<=0;
            xdiv<=0;ydiv<=0;xquot<=0;yquot<=0;xrem<=0;yrem<=0;div_count<=0;
            corner00<=0;corner01<=0;corner10<=0;corner11<=0;weight_x<=0;weight_y<=0;
            x0<=0;x1<=0;y0<=0;y1<=0;fx<=0;fy<=0;
        end else begin
            done<=0;
            if(in_done) source_done<=1;
            if(abort_load) begin state<=IDLE;source_done<=0;end
            else if(state!=IDLE && in_error) begin state<=IDLE;done<=1;error<=1;end
            else case(state)
                IDLE: if(start) begin
                    loaded_rows<=0;input_x<=0;output_x<=0;output_y<=0;
                    width_m1<=source_width-1'b1;width_m2<=source_width-2'd2;height_m1<=source_height-1'b1;
                    row_last<=source_width==1;
                    xpos<=0;ypos<=0;source_done<=0;error<=0;
                    xdiv<=({16'd0,source_width}-1)<<16;ydiv<=({16'd0,source_height}-1)<<16;
                    xquot<=0;yquot<=0;xrem<=0;yrem<=0;div_count<=0;
                    if(source_width==0 || source_width>MAX_WIDTH || source_height==0 || source_height>MAX_HEIGHT) begin done<=1;error<=1;end
                    else state<=DIVIDE;
                end
                DIVIDE: begin
                    xdiv<=xdiv<<1;ydiv<=ydiv<<1;
                    xrem<=xsub?xr-(OUT_WIDTH>1?OUT_WIDTH-1:1):xr;
                    yrem<=ysub?yr-(OUT_HEIGHT>1?OUT_HEIGHT-1:1):yr;
                    xquot<={xquot[30:0],xsub};yquot<={yquot[30:0],ysub};div_count<=div_count+1'b1;
                    if(div_count==31) begin
                        xstep<=OUT_WIDTH>1?{xquot[30:0],xsub}:0;
                        ystep<=OUT_HEIGHT>1?{yquot[30:0],ysub}:0;state<=COORD0;
                    end
                end
                COORD0: begin
                    x0<=output_x==OUT_WIDTH-1?width_m1:xpos[SW+15:16];
                    y0<=output_y==OUT_HEIGHT-1?height_m1:ypos[SH+15:16];
                    fx<=output_x==OUT_WIDTH-1?0:xpos[15:8];
                    fy<=output_y==OUT_HEIGHT-1?0:ypos[15:8];state<=COORD1;
                end
                COORD1: begin x1<=x0<width_m1?x0+1'b1:x0;y1<=y0<height_m1?y0+1'b1:y0;state<=CHECK;end
                CHECK: state<=loaded_rows<=y1?FILL:READ0;
                // row_last==(input_x==width-1); width_m2 is only compared when width>=2.
                FILL: if(in_valid && in_ready) begin
                    if(row_last) begin input_x<=0;row_last<=width_m1==0;loaded_rows<=loaded_rows+1'b1;state<=CHECK;end
                    else begin input_x<=input_x+1'b1;row_last<=input_x==width_m2;end
                end
                READ0: state<=READ1;
                READ1: state<=HORIZONTAL;
                HORIZONTAL: begin
                    corner00<=p00;corner01<=p01;corner10<=p10;corner11<=p11;weight_x<=fx;weight_y<=fy;
                    state<=START_H;
                end
                START_H: state<=WAIT_H;
                WAIT_H: if(blend_valid0 && blend_valid1) begin h0<=blend0;h1<=blend1;state<=VERTICAL;end
                VERTICAL: state<=WAIT_V;
                WAIT_V: if(blend_valid0) begin out_data<=blend0;state<=OUTPUT_PIXEL;end
                OUTPUT_PIXEL: if(out_ready) state<=ADVANCE;
                ADVANCE: begin
                    if(output_x==OUT_WIDTH-1) begin
                        output_x<=0;xpos<=0;output_y<=output_y+1'b1;ypos<=ypos+ystep;
                        state<=output_y==OUT_HEIGHT-1?FINISH:COORD0;
                    end else begin output_x<=output_x+1'b1;xpos<=xpos+xstep;state<=COORD0;end
                end
                FINISH: if(source_done || in_done) begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// Difference, multiplication, accumulation each have a separate register stage.
module rgb_lerp(
    input wire clk,rst,enable,input wire [23:0] a,b,input wire [7:0] weight,
    output wire valid,output wire [23:0] result
);
    reg [2:0] valids;
    reg [23:0] base0,base1;
    reg [7:0] f;
    assign valid=valids[2];
    always @(posedge clk or posedge rst) begin
        if(rst) begin valids<=0;base0<=0;base1<=0;f<=0;end
        else begin valids<={valids[1:0],enable};base0<=a;base1<=base0;f<=weight;end
    end
    genvar channel;
    generate for(channel=0;channel<3;channel=channel+1) begin: component
        reg signed [8:0] delta;
        reg signed [17:0] product;
        reg [7:0] output_color;
        wire signed [18:0] sum=$signed({1'b0,base1[channel*8 +: 8],8'd0})+product+19'sd128;
        assign result[channel*8 +: 8]=output_color;
        always @(posedge clk or posedge rst) begin
            if(rst) begin delta<=0;product<=0;output_color<=0;end
            else begin
                delta<=$signed({1'b0,b[channel*8 +: 8]})-$signed({1'b0,a[channel*8 +: 8]});
                product<=delta*$signed({1'b0,f});output_color<=sum[15:8];
            end
        end
    end endgenerate
endmodule
