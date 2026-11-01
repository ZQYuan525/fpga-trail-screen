`timescale 1ns/1ps
module tb_media_audio;
    reg clk=0,rst=1,mode=1,valid=0;reg [1:0] index=0;
    always #20 clk=~clk;
    wire av,acr;wire [23:0] left,right;wire [19:0] cts,n;
    integer cycles=0,samples=0,last_cycle=0,acrs=0,last_acr=0,last_pcm=0,delta;
    integer k;
    audio_tone_i2s #(.ENABLE_MEDIA(1)) dut(.clk(clk),.rst(rst),.media_mode(mode),.media_valid(valid),.media_index(index),
        .audio_valid(av),.audio_left(left),.audio_right(right),.acr_valid(acr),.acr_cts(cts),.acr_n(n));
    always @(negedge clk) if(!rst) begin
        cycles=cycles+1;
        if(av) begin
            if(^left===1'bx || left!==right || $signed(left)>1048575 || $signed(left)<-1048576) $fatal(1,"invalid PCM");
            if(last_cycle && cycles-last_cycle!=520 && cycles-last_cycle!=521) $fatal(1,"sample stream interrupted");
            delta=$signed(left)-last_pcm;if(delta>300000 || delta< -300000) $fatal(1,"abrupt waveform step %0d",delta);
            last_pcm=$signed(left);samples=samples+1;last_cycle=cycles;
        end
        if(acr) begin
            if(!av || samples%48!=0 || cts!=25000 || n!=6144 || (last_acr && cycles-last_acr!=25000)) $fatal(1,"ACR interrupted");
            acrs=acrs+1;last_acr=cycles;
        end
    end
    task sample;
        begin @(posedge clk);while(!av) @(posedge clk);end
    endtask
    task frequency(input integer period_samples);
        integer i,previous,first_cross,second_cross;begin
            @(negedge clk);
            wait(dut.gain==64 && !dut.changing);
            previous=0;first_cross=-1;second_cross=-1;
            for(i=0;i<period_samples*3;i=i+1) begin
                sample();
                if(i>0 && previous<=0 && $signed(left)>0) begin
                    if(first_cross<0) first_cross=i;
                    else if(second_cross<0) second_cross=i;
                end
                previous=$signed(left);
            end
            if(first_cross<0 || second_cross-first_cross!=period_samples) $fatal(1,"tone period expected=%0d got=%0d",period_samples,second_cross-first_cross);
        end
    endtask
    initial begin
        #91;rst=0;
        repeat(100) begin sample();if(left!==0) $fatal(1,"media before first image must be silent");end
        valid=1;frequency(96);index=1;frequency(64);index=2;frequency(48);index=3;frequency(32);
        mode=0;frequency(48); // independent test tone
        valid=0;frequency(48); // test tone does not require an image
        mode=1;repeat(200) sample();if(left!==0) $fatal(1,"media mute did not fade out");
        valid=1;
        for(k=0;k<16;k=k+1) begin index=k;mode=k%2;repeat(8) sample();end
        mode=1;index=0;frequency(96);
        wait(cycles>=2500000);@(posedge clk);
        if(samples!=4800 || acrs!=100) $fatal(1,"exact average rate %0d/%0d",samples,acrs);
        $display("PASS media_audio: four image pitches, test source, silent startup, fade bounded steps, uninterrupted exact PCM/ACR");$finish;
    end
    initial begin #110000000;$fatal(1,"media audio timeout");end
endmodule
