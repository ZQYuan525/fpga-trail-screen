`timescale 1ns/1ps
module tb_spectrum;
    reg clk=0,rst=1,sv=0,frame=0;reg signed [23:0] sample=0;
    always #5 clk=~clk;
    // levels mirrors the displayed bank, read through the one-clock bin port.
    reg [255:0] levels=0;reg [4:0] rd_bin=0;wire [7:0] rd_level;wire valid,overflow;wire [31:0] blocks,dropped;
    integer n,k,before_blocks;
    audio_spectrum dut(.clk(clk),.rst(rst),.sample_valid(sv),.sample(sample),.frame_start(frame),
        .rd_bin(rd_bin),.rd_level(rd_level),.valid(valid),.overflow(overflow),.blocks(blocks),.dropped_samples(dropped));
    task block(input integer amplitude,bin);
        begin
            before_blocks=blocks;
            for(n=0;n<64;n=n+1) begin
                @(negedge clk);sv=1;sample=$rtoi(amplitude*$cos(6.283185307179586*bin*n/64.0))*256;
                @(negedge clk);sv=0;repeat(199) @(negedge clk);
            end
            wait(blocks==before_blocks+1);
        end
    endtask
    task readback;
        integer b;
        begin for(b=0;b<32;b=b+1) begin rd_bin=b;@(posedge clk);#1 levels[b*8 +: 8]=rd_level;end end
    endtask
    task commit;
        begin @(negedge clk);frame=1;@(negedge clk);frame=0;readback();end
    endtask
    initial begin
        #23;rst=0;block(0,0);
        if(valid) $fatal(1,"spectrum committed mid-frame");
        commit();if(!valid || levels!==0) $fatal(1,"zero spectrum");
        block(4000,2);readback();
        if(levels!==0) $fatal(1,"FFT result not held until frame boundary");
        commit();
        for(k=0;k<32;k=k+1) begin
            if(k==2) begin if(levels[k*8 +: 8]<30 || levels[k*8 +: 8]>32) $fatal(1,"FFT peak/bin scale %d",levels[k*8 +: 8]);end
            else if(levels[k*8 +: 8]>1) $fatal(1,"FFT unexpected bin %d",k);
        end
        block(8000,2);commit();if(levels[16 +: 8]<61 || levels[16 +: 8]>63) $fatal(1,"FFT amplitude ratio");
        block(0,2);commit();if(levels[16 +: 8]<46 || levels[16 +: 8]>48) $fatal(1,"FFT decay %d",levels[16 +: 8]);
        if(overflow || dropped) $fatal(1,"sparse PCM lost samples");
        @(negedge clk);sv=1;repeat(80) @(negedge clk);sv=0;
        if(!overflow || dropped==0) $fatal(1,"dense PCM overflow not reported");
        rst=1;repeat(3) @(negedge clk);rst=0;block(0,0);commit();
        if(overflow || dropped || levels!==0) $fatal(1,"FFT reset recovery");
        $display("PASS spectrum: real r22sdf, zero, bin 2, amplitude, decay, frame commit, overload and reset");$finish;
    end
    initial begin #3000000;$fatal(1,"spectrum timeout blocks=%d",blocks);end
endmodule
