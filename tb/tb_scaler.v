`timescale 1ns/1ps
module tb_scaler;
    localparam W=8,H=6;
    reg clk=0,rst=1,start=0,abort_load=0,iv=0,finish_in=0,ie=0,ready=0;
    always #5 clk=~clk;
    reg [15:0] sw=1,sh=1;
    wire ir,ov,done,error,idle;wire [23:0] data;
    integer sent=0,received=0,cycle=0;
    reg stalled=0;reg [23:0] held;
    function [23:0] pixel(input integer x,y);
        pixel={8'(x*13+y*7),8'(x*3+y*19),8'(x*9+y*11)};
    endfunction
    wire [23:0] input_data=pixel(sent%sw,sent/sw);
    bilinear_scaler #(.OUT_WIDTH(W),.OUT_HEIGHT(H),.MAX_WIDTH(1280)) dut(
        .clk(clk),.rst(rst),.start(start),.abort_load(abort_load),.source_width(sw),.source_height(sh),
        .in_valid(iv),.in_data(input_data),.in_ready(ir),.in_done(finish_in),.in_error(ie),
        .out_valid(ov),.out_data(data),.out_ready(ready),.done(done),.error(error),.idle(idle));
    function integer blend(input integer a,b,f);
        blend=(a*(256-f)+b*f+128)/256;
    endfunction
    function [23:0] expected(input integer n);
        integer xx,yy,xf,yf,x0,y0,x1,y1,k,c0,c1,result;
        reg [23:0] a,b,c,d;
        begin
            xx=n%W;yy=n/W;
            xf=xx==W-1?(sw-1)*65536:xx*((sw-1)*65536/(W-1));
            yf=yy==H-1?(sh-1)*65536:yy*((sh-1)*65536/(H-1));
            x0=xf/65536;y0=yf/65536;x1=x0+1<sw?x0+1:x0;y1=y0+1<sh?y0+1:y0;
            a=pixel(x0,y0);b=pixel(x1,y0);c=pixel(x0,y1);d=pixel(x1,y1);expected=0;
            for(k=0;k<3;k=k+1) begin
                c0=blend((a>>(k*8))&255,(b>>(k*8))&255,(xf>>8)&255);
                c1=blend((c>>(k*8))&255,(d>>(k*8))&255,(xf>>8)&255);
                result=blend(c0,c1,(yf>>8)&255);expected=expected|(result<<(k*8));
            end
        end
    endfunction
    always @(negedge clk) begin
        cycle=cycle+1;ready=cycle%7<4;iv=sent<sw*sh && cycle%5!=0;finish_in=sent==sw*sh;
    end
    always @(posedge clk) if(!rst && !abort_load) begin
        if(iv && ir) sent=sent+1;
        if(stalled && ov && data!==held) $fatal(1,"scaler unstable under backpressure");
        stalled=ov && !ready;held=data;
        if(ov && ready) begin
            if(data!==expected(received)) $fatal(1,"scaler %0dx%0d pixel %0d: %h expected %h",sw,sh,received,data,expected(received));
            received=received+1;
        end
    end
    task run_case(input integer w,h);
        begin
            wait(idle);@(negedge clk);sw=w;sh=h;sent=0;received=0;stalled=0;start=1;
            @(negedge clk);start=0;wait(done);@(negedge clk);
            if(error || received!=W*H || sent!=w*h) $fatal(1,"scaler frame completion");
        end
    endtask
    initial begin
        #23;rst=0;run_case(1,1);run_case(5,3);run_case(8,6);run_case(13,9);run_case(1280,1);run_case(1,960);
        @(negedge clk);sent=0;received=0;start=1;@(negedge clk);start=0;
        wait(received==10);@(negedge clk);abort_load=1;@(negedge clk);abort_load=0;
        run_case(7,5);
        $display("PASS scaler: 1x1, identity, up/down scale, bilinear golden model, backpressure, abort/reload");$finish;
    end
    initial begin #2000000;$fatal(1,"scaler timeout");end
endmodule
