`timescale 1ns/1ps
// Reproducible FAT32/WAV composition stress.  The four cases exercise
// 4/8/32 KiB clusters, a FAT-page crossing chain, data offsets at a cluster
// boundary, deterministic service jitter, and an explicit out-of-budget stop.
module tb_filesystem_audio_stress;
    reg clk=0,vc=0,rst=1;
    always #5 clk=~clk;
    always #20 vc=~vc;

    integer scenario=0,spc=8,audio_offset=4094,fmt_offset=4062,junk_size=4041;
    integer nsamples=256,volume_length=560000,fat_length=600;
    integer service=-1,delay_count=0,active_lba=0,reads=0;
    integer samples=0,nonzero=0,silence=0,expected_index=0,vc_count=0;
    integer jitter_seed=32'h1a2b3c4d,pause_remaining=0,last_req_cycle=-1,min_req_gap=0,max_req_gap=0;
    integer target_samples=0,case_samples=0,case_silence=0,case_misses=0;
    integer audio_acc=0,model_misses=0,model_minimum=512,sd_cycles=0;
    integer logical_start=0,max_latency=0,rewinds=0,prior_address=0;
    integer fat_page0=0,fat_page1=0,request_log,case_seed;
    integer service_start=0,min_service=0,max_service=0,post_pause_samples=0;
    reg can_output;
    reg pause_done=0;
    reg [7:0] sd=0;
    reg sbusy=0,sv=0,se=0,tick=0;
    wire mounted,raw,wav,req,busy,valid,ending,error,sreq,ready,underflow;
    wire [31:0] address,lba,size;
    wire [7:0] data,fs_error,fault;
    wire signed [23:0] left,right;
    wire [15:0] misses;
    wire [9:0] minimum;

    fat32_media fs(.clk(clk),.rst(rst),.init_done(!rst),.mounted(mounted),.raw_mode(raw),.fs_error(fs_error),
        .catalog_start(1'b0),.catalog_resume(1'b0),.catalog_done(),.catalog_complete(),.found_valid(),.found_handle(),.found_total(),
        .wav_present(wav),.wav_size(size),
        .req(req),.address(address),.busy(busy),.data(data),.valid(valid),.ending(ending),.error(error),
        .sector_req(sreq),.sector_addr(lba),.sector_busy(sbusy),.sector_valid(sv),.sector_end(se),.sector_error(1'b0),.sector_data(sd));
    wav_player audio(.clk(clk),.video_clk(vc),.rst(rst),.enable(mounted && wav),.file_size(size),
        .req(req),.address(address),.busy(busy),.valid(valid),.ending(ending),.error(error),.data(data),
        .sample_tick(tick),.play(1'b1),.left(left),.right(right),.ready(ready),.fault(fault),.underflow(underflow),
        .missed_samples(misses),.minimum_level(minimum));

    wire [31:0] file_size = audio_offset + nsamples*4;
    function [7:0] wav_byte(input integer p);
        integer value,n,component;
        begin
            wav_byte=0;
            case(p)
                0:wav_byte="R";1:wav_byte="I";2:wav_byte="F";3:wav_byte="F";
                8:wav_byte="W";9:wav_byte="A";10:wav_byte="V";11:wav_byte="E";
                12:wav_byte="J";13:wav_byte="U";14:wav_byte="N";15:wav_byte="K";
            endcase
            case(p-fmt_offset)
                0:wav_byte="f";1:wav_byte="m";2:wav_byte="t";3:wav_byte=" ";4:wav_byte=16;
                8:wav_byte=1;10:wav_byte=2;20:wav_byte=4;22:wav_byte=16;
                24:wav_byte="d";25:wav_byte="a";26:wav_byte="t";27:wav_byte="a";
            endcase
            if(p>=16 && p<=19) wav_byte=junk_size>>((p-16)*8);
            if(p>=4 && p<=7) wav_byte=(file_size-8)>>((p-4)*8);
            if(p>=fmt_offset+12 && p<=fmt_offset+15) wav_byte=48000>>((p-fmt_offset-12)*8);
            if(p>=fmt_offset+16 && p<=fmt_offset+19) wav_byte=192000>>((p-fmt_offset-16)*8);
            if(p>=audio_offset-4 && p<audio_offset) wav_byte=(nsamples*4)>>((p-audio_offset+4)*8);
            if(p>=audio_offset) begin
                n=(p-audio_offset)/4;component=((p-audio_offset)/2)%2;
                value=component==0?n+100:-n-200;
                wav_byte=value>>(((p-audio_offset)%2)*8);
            end
        end
    endfunction

    function integer chain_slot(input integer cluster);
        begin
            if(cluster==5) chain_slot=0;
            else if(cluster==139) chain_slot=1;
            else if(cluster==9) chain_slot=2;
            else begin chain_slot=-1;$fatal(1,"unexpected data cluster %0d",cluster);end
        end
    endfunction
    function [31:0] fat_value(input integer cluster);
        begin
            if(cluster==2) fat_value=32'h0fffffff;
            else if(cluster==5) fat_value=139;
            else if(cluster==139) fat_value=9;
            else fat_value=32'h0fffffff;
        end
    endfunction
    function [7:0] disk(input integer a,p);
        integer relative,cluster,slot,sector_in,position,v;
        begin
            disk=0;relative=a-(32+fat_length);
            if(a==0) begin
                if(p==12) disk=2;if(p==13) disk=spc;if(p==14) disk=32;if(p==16) disk=1;
                if(p>=32 && p<36) disk=volume_length>>((p-32)*8);
                if(p>=36 && p<40) disk=fat_length>>((p-36)*8);
                if(p==44) disk=2;if(p==510) disk=8'h55;if(p==511) disk=8'haa;
            end else if(a>=32 && a<32+fat_length) begin
                cluster=(a-32)*128+p/4;v=fat_value(cluster);disk=v>>((p%4)*8);
            end else if(relative>=0 && relative<spc) begin
                // Root directory (cluster 2) contains one WAV entry.
                if(p==0) disk="A";if(p==8) disk="W";if(p==9) disk="A";if(p==10) disk="V";
                if(p==11) disk=8'h20;if(p==26) disk=5;
                if(p>=28 && p<32) disk=file_size>>((p-28)*8);
            end else begin
                cluster=(a-(32+fat_length))/spc+2;sector_in=(a-(32+fat_length))%spc;
                slot=chain_slot(cluster);position=slot*spc*512+sector_in*512+p;
                disk=wav_byte(position);
            end
        end
    endfunction

    always @(negedge clk) begin
        sv=0;se=0;
        if(rst) begin service=-1;sbusy=0;pause_remaining=0;pause_done=0;sd_cycles=0;end
        else if(service>=0) begin
            if(pause_remaining>0) pause_remaining=pause_remaining-1;
            else if(scenario==3 && !pause_done && nonzero>=600) begin
                // 20 ms > the nominal 10.67 ms FIFO store: this must underflow.
                pause_done=1;pause_remaining=2_000_000;
            end else if(delay_count>0) delay_count=delay_count-1;
            else if(service<512) begin
                sd=disk(active_lba,service);sv=1;service=service+1;
                jitter_seed=(jitter_seed*1103515245+12345)&32'h7fffffff;
                // 4 us wire time at 2 MHz plus a small seeded 0..30 ns
                // byte-engine jitter. The command/token gap below is 80 us.
                delay_count=399+(jitter_seed%4);
            end else begin
                se=1;sbusy=0;service=-1;
                if(min_service==0 || sd_cycles-service_start<min_service) min_service=sd_cycles-service_start;
                if(sd_cycles-service_start>max_service) max_service=sd_cycles-service_start;
                $fdisplay(request_log,"%0d,physical,%0d,%0d,%0d",scenario,active_lba,service_start,sd_cycles);
            end
        end else if(sreq) begin
            active_lba=lba;service=0;delay_count=8000;sbusy=1;reads=reads+1;service_start=sd_cycles;
            if(lba==32) fat_page0=fat_page0+1;
            if(lba==33) fat_page1=fat_page1+1;
            if(last_req_cycle>=0) begin
                if(min_req_gap==0 || sd_cycles-last_req_cycle<min_req_gap) min_req_gap=sd_cycles-last_req_cycle;
                if(sd_cycles-last_req_cycle>max_req_gap) max_req_gap=sd_cycles-last_req_cycle;
            end
            last_req_cycle=sd_cycles;
        end
        if(!rst) begin
            sd_cycles=sd_cycles+1;
            if(req) begin
                if(address<prior_address) rewinds=rewinds+1;
                prior_address=address;logical_start=sd_cycles;
            end
            if(ending) begin
                if(sd_cycles-logical_start>max_latency) max_latency=sd_cycles-logical_start;
                $fdisplay(request_log,"%0d,logical,%0d,%0d,%0d",scenario,address,logical_start,sd_cycles);
            end
            if(fs_error || fault) $fatal(1,"media error case=%0d fs=%h wav=%h",scenario,fs_error,fault);
        end
    end
    always @(negedge vc) begin
        if(rst) begin vc_count=0;tick=0;audio_acc=0;end
        else begin
            vc_count=vc_count+1;tick=0;audio_acc=audio_acc+48000;
            if(audio_acc>=25000000) begin audio_acc=audio_acc-25000000;tick=1;end
        end
    end
    always @(posedge vc) if(!rst && tick && audio.started && audio.ready_sync[2]) begin
        can_output=audio.holding;
        if(audio.used<model_minimum) model_minimum=audio.used;
        if(!can_output && model_misses<65535) model_misses=model_misses+1;
        #1;
        samples=samples+1;
        if(misses!==model_misses || minimum!==model_minimum || underflow!==(model_misses!=0))
            $fatal(1,"telemetry mismatch misses=%0d/%0d minimum=%0d/%0d",misses,model_misses,minimum,model_minimum);
        if(!can_output) begin
            if(left!==0 || right!==0) $fatal(1,"underflow did not output stereo silence");
            silence=silence+1;
        end else begin
            nonzero=nonzero+1;
            if(left!==24'((expected_index+100)*256) || right!==24'((-expected_index-200)*256))
                $fatal(1,"PCM order case=%0d sample=%0d got=%d/%d expected_index=%0d",scenario,samples,left,right,expected_index);
            expected_index=(expected_index+1)%nsamples;
            if(pause_done && pause_remaining==0) post_pause_samples=post_pause_samples+1;
        end
    end

    task run_case(input integer sc,input integer geometry,input integer offset,input integer want_samples,input integer expect_underflow);
        begin
            scenario=sc;spc=geometry;audio_offset=offset;fmt_offset=offset-32;junk_size=offset-53;
            volume_length=70000*geometry;nsamples=(offset<4096?geometry*256:geometry*128)+257;target_samples=2*nsamples+64;
            service=-1;reads=0;samples=0;nonzero=0;silence=0;expected_index=0;vc_count=0;
            last_req_cycle=-1;min_req_gap=0;max_req_gap=0;jitter_seed=32'h1a2b3c4d+sc;pause_done=0;pause_remaining=0;
            case_seed=jitter_seed;model_misses=0;model_minimum=512;
            fat_page0=0;fat_page1=0;rewinds=0;prior_address=0;max_latency=0;
            min_service=0;max_service=0;post_pause_samples=0;
            rst=1;repeat(8) @(negedge clk);rst=0;
            wait(ready || fault || fs_error!=0);
            wait(nonzero>=target_samples);@(negedge vc);
            case_samples=samples;case_silence=silence;case_misses=misses;
            if(fs_error || fault || !ready) $fatal(1,"stress case=%0d media fault fs=%h wav=%h",sc,fs_error,fault);
            if(expect_underflow) begin
                if(!underflow || case_silence<3 || case_misses<3 || minimum!=0 || post_pause_samples<512)
                    $fatal(1,"budget-out case did not report silent recovery");
            end else begin
                if(underflow || case_silence!=0 || nonzero<target_samples || minimum==0) $fatal(1,"budget-in case underflow/minimum=%b/%0d",underflow,minimum);
            end
            if(min_req_gap<=0 || max_req_gap<min_req_gap) $fatal(1,"request interval missing case=%0d",sc);
            if(rewinds<2 || fat_page0<2 || fat_page1<2) $fatal(1,"two loop/FAT-page coverage missing");
            $display("STRESS case=%0d seed=%h cluster=%0dKiB offset=%0d file_frames=%0d played=%0d ticks=%0d silence=%0d misses=%0d FIFOmin=%0d req_gap_sd=%0d..%0d physical_service_sd=%0d..%0d max_logical_sd=%0d rewinds=%0d fat_pages=%0d/%0d post_pause=%0d",sc,case_seed,geometry/2,offset,nsamples,nonzero,case_samples,case_silence,case_misses,minimum,min_req_gap,max_req_gap,min_service,max_service,max_latency,rewinds,fat_page0,fat_page1,post_pause_samples);
            rst=1;
        end
    endtask

    initial begin
        request_log=$fopen("filesystem_audio_stress_requests.csv","w");
        if(!request_log) $fatal(1,"cannot open request trace");
        $fdisplay(request_log,"case,kind,address,start_sd_cycle,end_sd_cycle");
        // Boundary offsets force the WAV payload across the first FAT-page
        // chain edge even when the payload itself is short.
        run_case(0,8,510,600,0);
        run_case(1,16,8190,600,0);
        run_case(2,64,32766,600,0);
        run_case(3,8,510,900,1);
        $display("PASS filesystem_audio_stress: seeded jitter, 4/8/32KiB clusters, FAT-page crossing, boundary offsets, two-loop PCM, request spacing, and explicit budget-out silent recovery");
        $fclose(request_log);$finish;
    end
    initial begin #900000000;$fatal(1,"filesystem stress watchdog scenario=%0d samples=%0d fs=%h wav=%h",scenario,samples,fs_error,fault);end
endmodule
