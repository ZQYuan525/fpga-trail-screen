`timescale 1ns/1ps
module tb_audio_gain;
    reg clk=0,rst=1,valid=0,acr=0;
    always #5 clk=~clk;
    reg [2:0] volume=4;
    wire ov,oa;
    wire signed [23:0] l,r;
    integer i,level,expected,previous;
    audio_gain dut(.clk(clk),.rst(rst),.valid_in(valid),.acr_in(acr),.volume(volume),
        .left_in(24'sd640000),.right_in(-24'sd640000),.valid_out(ov),.acr_out(oa),.left_out(l),.right_out(r));
    task sample;
        begin
            @(negedge clk);valid=1;acr=1;
            @(negedge clk);
            if(!ov || !oa || l !== -r || l>640000 || l<0) $fatal(1,"gain sign/range/timing");
            valid=0;acr=0;
            @(negedge clk);if(ov || oa) $fatal(1,"gain duplicated PCM/ACR");
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;sample();
        if(l!=640000) $fatal(1,"full volume not exact identity");
        volume=0;previous=l;
        for(i=0;i<66;i=i+1) begin sample();if(previous-l>10000 || l>previous) $fatal(1,"mute discontinuity");previous=l;end
        if(l!=0 || r!=0) $fatal(1,"mute not silent");
        for(level=1;level<=4;level=level+1) begin
            volume=level;
            repeat(66) sample();expected=level*160000;
            if(l!=expected || r!=-expected) $fatal(1,"volume level incorrect %d %d",level,l);
        end
        $display("PASS audio_gain: signed stereo, all five gains, exact unity, zero mute, bounded ramp and PCM/ACR timing");$finish;
    end
endmodule
