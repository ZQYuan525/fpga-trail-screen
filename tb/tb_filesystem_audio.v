`timescale 1ns/1ps
// Real FAT32 translator and WAV/FIFO path. The sector service includes a
// conservative 2 MHz SPI byte budget; files cross distant FAT pages.
module tb_filesystem_audio;
    reg clk=0,vc=0,rst=1;
    always #5 clk=~clk;always #20 vc=~vc;
    wire mounted,raw,wav,req,busy,valid,ending,error,sreq,ready,underflow;
    wire [31:0] address,lba,size;wire [7:0] data,fs_error,fault;
    wire signed [23:0] left,right;
    reg sbusy=0,sv=0,se=0,tick=0;
    reg [7:0] sd=0;
    integer service=-1,delay_count=0,active_lba=0,samples=0,vc_count=0,reads=0;
    integer min_req_gap=0,max_req_gap=0,last_req_cycle=-1;
    localparam NSAMPLES=3072,FILE_SIZE=44+NSAMPLES*4;
    fat32_media fs(.clk(clk),.rst(rst),.init_done(!rst),.mounted(mounted),.raw_mode(raw),.fs_error(fs_error),
        .catalog_start(1'b0),.catalog_done(),.found_valid(),.found_handle(),.found_total(),.wav_present(wav),.wav_size(size),
        .req(req),.address(address),.busy(busy),.data(data),.valid(valid),.ending(ending),.error(error),
        .sector_req(sreq),.sector_addr(lba),.sector_busy(sbusy),.sector_valid(sv),.sector_end(se),.sector_error(1'b0),.sector_data(sd));
    wav_player audio(.clk(clk),.video_clk(vc),.rst(rst),.enable(mounted && wav),.file_size(size),
        .req(req),.address(address),.busy(busy),.valid(valid),.ending(ending),.error(error),.data(data),
        .sample_tick(tick),.play(1'b1),.left(left),.right(right),.ready(ready),.fault(fault),.underflow(underflow));
    function [7:0] wav_byte(input integer p);
        integer value;
        begin
            wav_byte=0;
            case(p)
                0:wav_byte="R";1:wav_byte="I";2:wav_byte="F";3:wav_byte="F";
                8:wav_byte="W";9:wav_byte="A";10:wav_byte="V";11:wav_byte="E";
                12:wav_byte="f";13:wav_byte="m";14:wav_byte="t";15:wav_byte=" ";16:wav_byte=16;
                20:wav_byte=1;22:wav_byte=2;32:wav_byte=4;34:wav_byte=16;
                36:wav_byte="d";37:wav_byte="a";38:wav_byte="t";39:wav_byte="a";
            endcase
            if(p>=4 && p<8) wav_byte=(FILE_SIZE-8)>>((p-4)*8);
            if(p>=24 && p<28) wav_byte=48000>>((p-24)*8);
            if(p>=28 && p<32) wav_byte=192000>>((p-28)*8);
            if(p>=40 && p<44) wav_byte=(NSAMPLES*4)>>((p-40)*8);
            if(p>=44) begin
                value=(p-44)%4<2?100+(p-44)/4:-200-(p-44)/4;
                wav_byte=value>>(((p-44)%2)*8);
            end
        end
    endfunction
    function [7:0] disk(input integer a,p);
        integer cluster,v,position;
        begin
            disk=0;
            if(a==0) begin
                if(p==12) disk=2;if(p==13) disk=8;if(p==14) disk=32;if(p==16) disk=1;
                if(p>=32 && p<36) disk=600000>>((p-32)*8);
                if(p>=36 && p<40) disk=600>>((p-36)*8);
                if(p==44) disk=2;if(p==510) disk=8'h55;if(p==511) disk=8'haa;
            end else if(a>=32 && a<632) begin
                cluster=(a-32)*128+p/4;
                v=cluster==5?139:cluster==139?9:cluster==9?270:32'h0fffffff;
                disk=v>>((p%4)*8);
            end else if(a==632) begin
                if(p==0) disk="A";if(p==8) disk="W";if(p==9) disk="A";if(p==10) disk="V";
                if(p==26) disk=5;if(p>=28 && p<32) disk=FILE_SIZE>>((p-28)*8);
            end else begin
                cluster=(a-632)/8+2;
                position=(cluster==5?0:cluster==139?1:cluster==9?2:3)*4096+((a-632)%8)*512+p;
                disk=wav_byte(position);
            end
        end
    endfunction
    always @(negedge clk) begin
        sv=0;se=0;
        if(rst) begin service=-1;sbusy=0;end
        else if(service>=0) begin
            if(delay_count!=0) delay_count=delay_count-1;
            else if(service<512) begin sd=disk(active_lba,service);sv=1;service=service+1;delay_count=411;end
            else begin se=1;sbusy=0;service=-1;end
        end else if(sreq) begin
            active_lba=lba;service=0;delay_count=8000;sbusy=1;reads=reads+1;
            if(last_req_cycle>=0) begin
                if(min_req_gap==0 || vc_count-last_req_cycle<min_req_gap) min_req_gap=vc_count-last_req_cycle;
                if(vc_count-last_req_cycle>max_req_gap) max_req_gap=vc_count-last_req_cycle;
            end
            last_req_cycle=vc_count;
        end
    end
    always @(negedge vc) begin
        if(rst) begin vc_count=0;tick=0;end
        else begin vc_count=vc_count+1;tick=vc_count%520==0;end // slightly faster than 48 kHz
    end
    always @(posedge vc) if(!rst && tick && audio.started) begin
        #1;
        if(left!==24'((samples%NSAMPLES+100)*256) || right!==24'((-samples%NSAMPLES-200)*256))
            $fatal(1,"fragmented FAT/WAV PCM mismatch at sample %0d L=%d R=%d",samples,left,right);
        samples=samples+1;
    end
    initial begin
        repeat(8) @(negedge clk);rst=0;wait(samples>=6144);
        if(fs_error || fault || underflow || !ready || reads<20) $fatal(1,"2 MHz fragmented stream error");
        if(min_req_gap<=0 || max_req_gap<=min_req_gap) $fatal(1,"service request interval was not measured");
        $display("PASS filesystem_audio: FAT32 4KiB fragmented clusters, FAT page changes, two complete loops (%0d frames), conservative 2MHz service, exact PCM, no underflow, request_gap=%0d..%0d VIDEO cycles",samples,min_req_gap,max_req_gap);$finish;
    end
    initial begin #200000000;$fatal(1,"filesystem audio watchdog samples=%0d fs=%h wav=%h",samples,fs_error,fault);end
endmodule
