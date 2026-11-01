`timescale 1ns/1ps
module tb_audio_source_mux;
    reg clk=0,rst=1,tick=0,acr=0,sel=0;
    always #20 clk=~clk;
    wire valid,acr_out;
    wire signed [23:0] left,right;
    integer n,previous=0;
    audio_source_mux dut(.clk(clk),.rst(rst),.sample_valid(tick),.acr_in(acr),.select_wav(sel),
        .tone_left(24'sd4194304),.tone_right(-24'sd4194304),.wav_left(-24'sd4194304),.wav_right(24'sd4194304),
        .valid(valid),.acr_out(acr_out),.left(left),.right(right));
    task sample;
        begin
            @(negedge clk);tick=1;acr=n%48==0;
            @(posedge clk);#1;
            if(!valid || acr_out!=acr || right!=-left) $fatal(1,"audio cadence/stereo sign");
            if(n!=0 && (left-previous>65536 || previous-left>65536)) $fatal(1,"source switch discontinuity");
            previous=left;
            @(negedge clk);tick=0;acr=0;
            @(posedge clk);#1;if(valid || acr_out) $fatal(1,"duplicated sample/ACR");
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(n=0;n<400;n=n+1) begin
            if(n==1) sel=1;if(n==160) sel=0;
            sample();
            if(n==150 && left!=-4194304) $fatal(1,"WAV full scale");
            if(n==399 && left!=4194304) $fatal(1,"tone full scale");
        end
        $display("PASS audio_source_mux: zero-gain switching, ramp bound, exact settled PCM, continuous valid/ACR");$finish;
    end
endmodule
