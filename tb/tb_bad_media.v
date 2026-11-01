`timescale 1ns/1ps
// Actual FAT catalog/address translation, BMP decoder and preload controller.
// A transaction-level frame sink checks every pixel; four_slot_memory covers
// the independent physical SDRAM controller and pin-level storage contract.
module tb_bad_media;
    wire wabort;wire [3:0] bad_slots;
    wire catalog_complete,catalog_continue;
    reg clk=0,vc=0,rst=1,next_key=0;
    always #5 clk=~clk;
    always #20 vc=~vc;
    wire mounted,raw,scan,catdone,found,req,busy,valid,ending,error,sreq;
    wire [31:0] handle,address,lba,load_sector;
    wire [2:0] total;wire [7:0] data,fs_error;
    wire start,abort_load,bmp_ready,breq,back,px,pxready,done,bad,progress,wreq,we,preloaded,pub,displayed,player_error;
    wire [23:0] rgb;wire [31:0] word_data;wire [1:0] wb,db,current,target;
    reg wack=0,puback=0,finish=0,sbusy=0,sv=0,se=0;reg [7:0] sd=0;
    integer service=-1,active_lba=0,reads=0,saved_reads,i,pixels=0;
    reg [3:0] frames=0;
    wire wav_present,wav_req,wav_ready,wav_underflow;
    wire [31:0] wav_address,wav_size;
    wire [7:0] wav_fault;
    wire signed [23:0] audio_left,audio_right;
    reg wav_owner=0,tick=0;
    integer audio_acc=0,audio_samples=0;
    always @(posedge clk) if(rst) wav_owner<=0;else wav_owner<=preloaded && wav_present;
    always @(posedge vc) begin
        tick<=0;
        if(rst) audio_acc<=0;
        else if(audio_acc>=25000000-48000) begin audio_acc<=audio_acc+48000-25000000;tick<=1;end
        else audio_acc<=audio_acc+48000;
        if(!rst && tick && audio_left!=0) begin
            if(audio_left!==24'h123400 || audio_right!==24'h123400) $fatal(1,"AV PCM changed during image switch");
            audio_samples=audio_samples+1;
        end
        if(wav_fault || wav_underflow) $fatal(1,"AV playback fault/underflow");
    end
    wav_player audio(.clk(clk),.video_clk(vc),.rst(rst),.enable(wav_owner),.file_size(wav_size),
        .req(wav_req),.address(wav_address),.busy(busy || !wav_owner),.valid(valid && wav_owner),
        .ending(ending && wav_owner),.error(error && wav_owner),.data(data),
        .sample_tick(tick),.play(1'b1),.left(audio_left),.right(audio_right),.ready(wav_ready),.fault(wav_fault),.underflow(wav_underflow));
    fat32_media #(.EARLY_CATALOG(1)) fs(.catalog_complete(catalog_complete),.catalog_resume(catalog_continue),.clk(clk),.rst(rst),.init_done(!rst),.mounted(mounted),.raw_mode(raw),.fs_error(fs_error),
        .catalog_start(scan),.catalog_done(catdone),.found_valid(found),.found_handle(handle),.found_total(total),.wav_present(wav_present),.wav_size(wav_size),
        .req(wav_owner?wav_req:req),.address(wav_owner?wav_address:address),.busy(busy),.data(data),.valid(valid),.ending(ending),.error(error),
        .sector_req(sreq),.sector_addr(lba),.sector_busy(sbusy),.sector_valid(sv),.sector_end(se),.sector_error(1'b0),.sector_data(sd));
    bmp_decoder #(.FLEXIBLE_SIZE(1)) bmp(.clk(clk),.rst(rst),.sd_init_done(mounted),.ready(bmp_ready),
        .sd_sec_read(req),.sd_sec_addr(address),.sd_sec_data(data),.sd_sec_data_valid(valid && !wav_owner),
        .sd_sec_end(ending && !wav_owner),.sd_sec_busy(busy || wav_owner),.sd_sec_error(error && !wav_owner),
        .bmp_width(16'd1280),.bmp_height(16'd960),.scan_start(1'b0),.scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
        .load_start(start),.load_abort(abort_load),.load_sector(load_sector),.write_req(breq),.write_req_ack(back),
        .px_wr_en(px),.px_data(rgb),.px_ready(pxready),.load_done(done),.load_error(bad),.progress(progress),.state_code(),
        .source_width(),.source_height(),.source_top_down());
    sd_player #(.SKIP_BAD(1),.STREAM_CATALOG(1),.PRELOAD(1),.KEY_EVENTS(1),.RUNTIME_CONTROL(1)) player(
        .clk(clk),.rst(rst),.key_next(next_key),.key_auto(1'b0),.key_prev(1'b0),.period_select(2'd0),.retry_load(1'b0),.sd_init_done(mounted),
        .current_image(current),.target_image(target),.auto_enabled(),.display_valid(displayed),.state_code(),.write_finish_t(finish),
        .write_req(wreq),.write_req_ack(wack),.write_en(we),.write_data(word_data),.write_ready(1'b1),.write_buf_idx(wb),.disp_buf_idx(db),
        .bmp_write_req(breq),.bmp_write_req_ack(back),.scan_start(scan),.load_start(start),.load_abort(abort_load),.load_sector(load_sector),
        .bmp_ready(bmp_ready),.scan_done(catdone),.scan_found_valid(found),.scan_found_sector(handle),.scan_found_total(total),
        .bmp_px_wr_en(px),.bmp_px_data(rgb),.bmp_px_ready(pxready),.bmp_load_done(done),.bmp_load_error(bad),.bmp_progress(progress),
        .write_abort(wabort),.write_abort_ack(wabort),.publish_req(pub),.publish_ack(puback),.error(player_error),.load_success(),.preload_done(preloaded),.catalog_complete(catalog_complete),.catalog_continue(catalog_continue),.bad_slots(bad_slots));
    function [7:0] disk(input integer a,p);
        integer item,off,v,cluster,position;
        begin
            disk=0;
            if(a==0) begin
                if(p==12) disk=2;if(p==13) disk=1;if(p==14) disk=32;if(p==16) disk=1;
                if(p>=32 && p<36) disk=70000>>((p-32)*8);
                if(p>=36 && p<40) disk=600>>((p-36)*8);
                if(p==44) disk=2;if(p==510) disk=8'h55;if(p==511) disk=8'haa;
            end else if(a==32) begin
                v=p/4==9?15:p/4==20?21:32'h0fffffff;disk=v>>((p%4)*8);
            end else if(a==632) begin
                item=p/32;off=p%32;
                if(item<4) begin
                    if(off==0) disk="A"+item;if(off==8) disk="B";if(off==9) disk="M";if(off==10) disk="P";
                    if(off==26) disk=5+item*2;
                    if(off>=28) disk=(item==2?724:78)>>((off-28)*8);
                end else if(item==4) begin
                    if(off==0) disk="S";if(off==8) disk="W";if(off==9) disk="A";if(off==10) disk="V";
                    if(off==26) disk=20;if(off>=28) disk=1024>>((off-28)*8);
                end
            end else if(a==650 || a==651) begin
                position=(a-650)*512+p;
                case(position)
                    0:disk="R";1:disk="I";2:disk="F";3:disk="F";
                    8:disk="W";9:disk="A";10:disk="V";11:disk="E";
                    12:disk="f";13:disk="m";14:disk="t";15:disk=" ";16:disk=16;
                    20:disk=1;22:disk=1;32:disk=2;34:disk=16;
                    36:disk="d";37:disk="a";38:disk="t";39:disk="a";
                endcase
                if(position>=4 && position<8) disk=1016>>((position-4)*8);
                if(position>=24 && position<28) disk=48000>>((position-24)*8);
                if(position>=28 && position<32) disk=96000>>((position-28)*8);
                if(position>=40 && position<44) disk=980>>((position-40)*8);
                if(position>=44) disk=position%2?8'h12:8'h34;
            end else begin
                cluster=a-632+2;item=cluster==15?2:(cluster-5)/2;
                position=cluster==15?p+512:p;off=item==2?700:54;
                case(position)
                    0:disk="B";1:disk="M";14:disk=40;18:disk=4;22:disk=2;26:disk=1;28:disk=item==2?16:24;
                endcase
                if(position>=2 && position<6) disk=(off+24)>>((position-2)*8);
                if(position>=10 && position<14) disk=off>>((position-10)*8);
                if(position>=off && position<off+24) disk=20+item*40+(position-off)%3;
            end
        end
    endfunction
    always @(negedge clk) begin
        sv=0;se=0;
        if(rst) begin service=-1;sbusy=0;wack=0;puback=0;end
        else begin
            wack=wreq;puback=pub;
            if(service>=0) begin
                if(service<512) begin sd=disk(active_lba,service);sv=1;service=service+1;end
                else begin se=1;sbusy=0;service=-1;end
            end else if(sreq) begin service=0;active_lba=lba;sbusy=1;reads=reads+1;end
        end
    end
    always @(posedge clk) if(!rst) begin
        if(start) begin pixels=0;if(load_sector!=={target,28'd0}) $fatal(1,"virtual BMP handle");end
        if(we) begin
            if(word_data!=={8'(22+wb*40),8'(21+wb*40),8'(20+wb*40),8'd0}) $fatal(1,"FAT/BMP RGB or image-slot mismatch");
            if(displayed && wb==db) $fatal(1,"background overwrote display");
            pixels=pixels+1;if(pixels==8) begin finish=~finish;frames[wb]=1;end
            if(pixels>8) $fatal(1,"extra BMP pixels");
        end
        if(fs_error || (done && bad && target!=2)) $fatal(1,"unexpected integrated media error fs=%h target=%d done=%b bad=%b",fs_error,target,done,bad);
        if(wav_owner && (start || req)) $fatal(1,"cached switch requested BMP/SD while WAV owns storage");
    end
    initial begin
        repeat(6) @(negedge clk);rst=0;wait(displayed);
        if(catalog_complete || total!=1) $fatal(1,"first image not displayed before directory completion");
        wait(preloaded);repeat(10) @(negedge clk);
        if(frames!=11 || bad_slots!=4 || current!=0 || total!=4 || raw) $fatal(1,"FAT four-image preload/catalog");
        saved_reads=reads;
        wait(audio_samples>=64);
        if(bmp_ready) $fatal(1,"AV test did not reserve storage for WAV");
        for(i=1;i<=4;i=i+1) begin
            next_key=1;@(negedge clk);next_key=0;wait(current==(i==1 || i==4?1:i==2?3:0));wait(player.state==2);repeat(5) @(negedge clk);
        end
        wait(audio_samples>=128);
        if(reads<=saved_reads || !wav_ready) $fatal(1,"WAV did not read while cached images switched");
        $display("PASS bad_media: corrupt BMP quarantined, valid siblings preloaded, actual WAV plays and continues through cached navigation; FAT/BMP four-slot preload, fragmented offset700 pixels, WAV storage ownership, valid PCM during cached wrap, no BMP reload");$finish;
    end
    initial begin #20000000;$fatal(1,"filesystem images watchdog fs=%d bmp=%d player=%d",fs.state,bmp.state,player.state);end
endmodule
