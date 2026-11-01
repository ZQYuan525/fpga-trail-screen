`timescale 1ns/1ps
module tb_diagnostic;
    reg clk=0,rst=1,ready=1;always #20 clk=~clk;
    wire hs,vs,de,req,ack,ren,rv,avs,ade,ahs,valid,user,last,overflow;
    wire [23:0] read_data,rgb,data;
    integer received=0,cycle=0,x,y;
    reg [23:0] expected;
    reg stalled=0;reg [25:0] held;
    video_timing_gen timing(.video_clk(clk),.rst(rst),.read_req(req),.read_req_ack(ack),.hs(hs),.vs(vs),.de(de));
    diagnostic_pattern pattern(.clk(clk),.rst(rst),.read_req(req),.read_en(ren),.read_ack(ack),.read_valid(rv),.read_data(read_data));
    video_pixel_align aligner(.video_clk(clk),.rst(rst),.read_en(ren),.read_data(read_data),.read_valid(rv),.display_enable(1'b1),
        .hs(hs),.vs(vs),.de(de),.hs_r(ahs),.vs_r(avs),.de_r(ade),.vout_data(rgb));
    rgb_to_axis axis(.clk(clk),.rst(rst),.i_vs(avs),.i_de(ade),.i_rgb(rgb),.i_ready(ready),
        .o_user(user),.o_valid(valid),.o_last(last),.o_data(data),.overflow(overflow));
    always @(negedge clk) begin cycle=cycle+1;ready=cycle%800!=170 && cycle%800!=171;end
    always @(posedge clk) if(!rst) begin
        if(stalled && {user,last,data}!==held) $fatal(1,"diagnostic payload changed under backpressure");
        stalled=valid && !ready;held={user,last,data};
        if(valid && ready) begin
            x=received%640;y=(received/640)%480;
            expected=(x==0 || x==639 || y==0 || y==479)?24'hffffff:{8'(x),8'(y),8'(received/307200+1)};
            if(data!==expected || user!==(received%307200==0) || last!==(x==639)) $fatal(1,"diagnostic pixel/SOF/EOL %0d got=%h expected=%h",received,data,expected);
            received=received+1;
        end
        if(overflow) $fatal(1,"diagnostic unexpected overflow");
    end
    initial begin #103;rst=0;wait(received==614400);$display("PASS diagnostic: two full coordinate frames, border, frame tag, alignment and AXIS backpressure");$finish;end
    initial begin #40000000;$fatal(1,"diagnostic timeout");end
endmodule
