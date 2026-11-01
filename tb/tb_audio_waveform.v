`timescale 1ns/1ps
module tb_audio_waveform;
    reg clk=0,rst=1,tick=0,frame=0;
    reg signed [23:0] pcm=0;
    always #5 clk=~clk;
    // samples mirrors the shown bank, read through the one-clock bin port.
    reg [255:0] samples=0;reg [4:0] rd_bin=0;wire [7:0] rd_sample,peak;wire valid;
    audio_waveform #(.DECIMATE(2)) dut(.clk(clk),.rst(rst),.sample_valid(tick),.frame_start(frame),.sample(pcm),.rd_bin(rd_bin),.rd_sample(rd_sample),.peak(peak),.valid(valid));
    task sample(input signed [23:0] value);begin @(negedge clk);pcm=value;tick=1;@(negedge clk);tick=0;end endtask
    task readback;integer b;begin for(b=0;b<32;b=b+1) begin rd_bin=b;@(posedge clk);#1 samples[b*8 +: 8]=rd_sample;end end endtask
    task commit;begin @(negedge clk);frame=1;@(negedge clk);frame=0;readback();end endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(i=0;i<64;i=i+1) sample((i%2?127:i/2)<<16);
        readback();
        if(valid || samples!==0 || peak!==0) $fatal(1,"capture leaked into display");
        sample(24'sh800000); // Peak after capture is full must still be included.
        commit();
        if(!valid || peak!=128) $fatal(1,"full-scale negative/all-sample peak");
        for(i=0;i<32;i=i+1) if(samples[i*8 +: 8]!=i) $fatal(1,"decimation/order");
        sample(0);commit();
        if(samples[31*8 +: 8]!=31 || peak!=0) $fatal(1,"incomplete capture or silent peak");
        for(i=0;i<64;i=i+1) sample(0);
        commit();if(samples!==0 || peak!=0) $fatal(1,"mute did not clear waveform");
        $display("PASS audio_waveform: exact decimation, atomic frame snapshot, incomplete capture, full-window peak, negative full scale, silence");$finish;
    end
    initial begin #100000;$fatal(1,"wave timeout");end
endmodule
