`timescale 1ns/1ps
module tb_video;
 reg clk=0,rst=1;always #20 clk=~clk;
 wire hs,vs,de,req,ren,ahs,avs,ade,valid,user,last,overflow;
 reg ack=0,rv=0,enable=1,ready=1;reg [23:0] rd=0;
 wire [23:0] rgb,axis_data;
 integer source=0,sink=0,sofs=0,lines=0,cycle=0,frame_requests=0;
 reg stalled=0;reg [25:0] held;
 function [23:0] pattern(input integer n);
 pattern={8'(n/640),8'(n%640),8'(n*3+19)};
 endfunction
 video_timing_gen timing(.video_clk(clk),.rst(rst),.read_req(req),.read_req_ack(ack),.hs(hs),.vs(vs),.de(de));
 video_pixel_align aligner(.video_clk(clk),.rst(rst),.read_en(ren),.read_data(rd),.read_valid(rv),.display_enable(enable),
 .hs(hs),.vs(vs),.de(de),.hs_r(ahs),.vs_r(avs),.de_r(ade),.vout_data(rgb));
 rgb_to_axis adapter(.clk(clk),.rst(rst),.i_vs(avs),.i_de(ade),.i_rgb(rgb),.i_ready(ready),
 .o_user(user),.o_valid(valid),.o_last(last),.o_data(axis_data),.overflow(overflow));
 // Independent registered memory interface, same latency as the real FIFO.
 always @(posedge clk) if(rst) begin rv<=0;source=0;end else begin
 rv<=ren;if(ren) begin rd<=pattern(source%307200);source=source+1;end
 end
 always @(negedge clk) begin
 cycle=cycle+1;ack=req;
 // Two-cycle stalls, once per line, including selected EOLs.
 ready=(cycle%800!=170 && cycle%800!=171 && cycle%800!=791 && cycle%800!=792);
 end
 always @(posedge clk) if(!rst) begin
 if(stalled && {user,last,axis_data}!==held) $fatal(1,"AXIS output changed under stall");
 stalled=valid && !ready;held={user,last,axis_data};
 if(valid && ready) begin
 if(axis_data!==pattern(sink%307200)) $fatal(1,"video alignment pixel=%0d got=%h expected=%h",sink,axis_data,pattern(sink%307200));
 if(user!==(sink%307200==0)) $fatal(1,"SOF pixel=%0d",sink);
 if(last!==(sink%640==639)) $fatal(1,"EOL pixel=%0d",sink);
 sink=sink+1;if(user) sofs=sofs+1;if(last) lines=lines+1;
 end
 if(overflow) $fatal(1,"queue overflow on bounded stalls");
 end
 initial begin #103;rst=0;wait(sink==614400);@(negedge clk);
 if(sofs!=2 || lines!=960 || source!=614400) $fatal(1,"video frame counts");
 $display("PASS video: 614400 RGB pixels, 960 EOL, 2 SOF, registered memory alignment, stable backpressure");$finish;end
 initial begin #40000000;$fatal(1,"video timeout count=%0d",sink);end
endmodule
