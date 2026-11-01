`timescale 1ns/1ps
module tb_control_audio;
 reg clk=0,slow=0,rst=1,rst_n=0,lock1=0,lock2=0;
 always #20 clk=~clk;always #13 slow=~slow;
 wire av,acr,reset_all,local_rst;wire [23:0] left,right;wire [19:0] cts,n;
 reg [3:0] status=0;wire [3:0] snapshot;
 integer cycles=0,samples=0,acrs=0,last_sample=0,last_acr=0,k,expected;
 real angle;
 audio_tone_i2s audio(.clk(clk),.rst(rst),.media_mode(1'b0),.media_valid(1'b0),.media_index(2'd0),.audio_valid(av),.audio_left(left),.audio_right(right),.acr_valid(acr),.acr_cts(cts),.acr_n(n));
 reset_gen #(.LOCK_STABLE_CYCLES(8)) resetter(.clk(clk),.rst_n(rst_n),.sys_pll_lock(lock1),.video_pll_lock(lock2),.rst_all(reset_all));
 reset_sync local_reset(.clk(slow),.arst(reset_all),.rst(local_rst));
 status_snapshot cdc(.src_clk(clk),.src_rst(rst),.value(status),.dst_clk(slow),.dst_rst(rst),.snapshot(snapshot));
 always @(negedge clk) if(!rst) begin
 cycles=cycles+1;
 if(av) begin
 angle=6.283185307179586*(samples%48)/48.0;expected=$rtoi(1048575.0*$sin(angle));
 if($signed(left)-expected>2 || expected-$signed(left)>2 || left!==right) $fatal(1,"PCM LUT sample=%0d got=%0d exp=%0d",samples,$signed(left),expected);
 if(last_sample!=0 && cycles-last_sample!=520 && cycles-last_sample!=521) $fatal(1,"sample jitter");
 samples=samples+1;last_sample=cycles;
 end
 if(acr) begin
 if(!av || samples%48!=0 || cts!=25000 || n!=6144) $fatal(1,"ACR values/cadence");
 if(last_acr && cycles-last_acr!=25000) $fatal(1,"ACR interval");
 acrs=acrs+1;last_acr=cycles;
 end
 end
 initial begin
 #91;rst=0;rst_n=1;lock1=1;
 repeat(12) @(posedge clk);if(!reset_all) $fatal(1,"release without both locks");
 lock2=1;repeat(4) @(negedge clk);lock2=0;repeat(5) @(negedge clk);if(!reset_all) $fatal(1,"short lock accepted");
 lock2=1;wait(!reset_all);wait(!local_rst);
 @(negedge clk);lock1=0;repeat(12) @(negedge clk);if(reset_all) $fatal(1,"lock twitch policy");
 for(k=1;k<16;k=k+1) begin @(negedge clk);status=k;repeat(15) @(negedge clk);if(snapshot!=k) $fatal(1,"status CDC");end
 #7;rst_n=0;#1;if(!reset_all || !local_rst) $fatal(1,"async assertion");
 wait(cycles==2500000);
 if(samples!=4800 || acrs!=100) $fatal(1,"100ms PCM rates samples=%0d ACR=%0d",samples,acrs);
 $display("PASS control/audio: 4800 stereo samples/100ms, 1kHz LUT, 100 ACR, lock/reset/status CDC");$finish;
 end
 initial begin #110000000;$fatal(1,"audio timeout");end
endmodule
