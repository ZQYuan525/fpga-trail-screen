`timescale 1ns/1ps
module tb_fat32_media;
    reg clk=0,rst=1,init=0,cat=0,req=0;
    always #5 clk=~clk;
    reg [31:0] address=0;
    wire mounted,raw,busy,valid,ending,error,catdone,found,wav,sreq;
    wire [7:0] data,fs_error;
    wire [31:0] handle,wav_size,lba;
    wire [2:0] total;
    reg sbusy=0,sv=0,se=0,serr=0;
    reg [7:0] sd=0;
    integer service=-1,active_lba=0,partition=0,reads=0,received=0,found_count=0,corrupt=0;
    reg raw_card=0,bad_bpb=0,cycle=0,short_chain=0,root_cycle=0,short_sector=0;
    integer fats=1,active_fat=0;
    integer fat_length=600,volume_length=70000;
    integer before_reads;
    integer sectors_per_cluster=1,root_reads=0,geometry;
    fat32_media dut(.clk(clk),.rst(rst),.init_done(init),.mounted(mounted),.raw_mode(raw),.fs_error(fs_error),
        .catalog_start(cat),.catalog_done(catdone),.found_valid(found),.found_handle(handle),.found_total(total),
        .wav_present(wav),.wav_size(wav_size),.req(req),.address(address),.busy(busy),.data(data),.valid(valid),.ending(ending),.error(error),
        .sector_req(sreq),.sector_addr(lba),.sector_busy(sbusy),.sector_valid(sv),.sector_end(se),.sector_error(serr),.sector_data(sd));
    function [7:0] disk(input integer a,p);
        integer v,relative,base;
        begin
            disk=0;relative=a-partition;base=32+fat_length*fats;
            if(raw_card) begin if(p==0) disk="B";else if(p==1) disk="M";else disk=p;end
            else if(a==0 && partition!=0) begin
                if(p==498) disk=8'h0c;
                if(p>=502 && p<=505) disk=partition>>((p-502)*8);
                if(p>=506 && p<=509) disk=volume_length>>((p-506)*8);
                if(p==510) disk=8'h55;if(p==511) disk=8'haa;
            end else if(relative==0) begin
                if(p==12) disk=bad_bpb?4:2;
                if(p==13) disk=sectors_per_cluster;if(p==14) disk=32;if(p==16) disk=fats;
                if(p==40 && active_fat) disk=8'h81;
                if(p>=32 && p<=35) disk=volume_length>>((p-32)*8);
                if(p>=36 && p<=39) disk=fat_length>>((p-36)*8);
                if(p==44) disk=2;if(p==510) disk=8'h55;if(p==511) disk=8'haa;
            end else if(relative==32+fat_length*active_fat) begin
                v=p/4==2?8:p/4==8 && root_cycle?2:p/4==5?(short_chain?32'h0fffffff:9):p/4==9 && cycle?5:32'h0fffffff;
                disk=v>>((p%4)*8);
            end else if(relative>=base && relative<base+sectors_per_cluster) begin
                // Full first root sector; deleted/LFN entries cannot terminate scanning.
                if(p%32==0) disk=8'he5;
                if(relative==base && p<32) begin
                    if(p==0) disk="I";if(p==8) disk="B";if(p==9) disk="M";if(p==10) disk="P";
                    if(p==26) disk=5;if(p==29) disk=cycle?16:4;
                end
            end else if(relative==base+6*sectors_per_cluster) begin
                if(root_cycle && p%32==0) disk=8'he5;
                if(p==0) disk="A";if(p==8) disk="W";if(p==9) disk="A";if(p==10) disk="V";
                if(p==26) disk=10;if(p==29) disk=4;
            end else disk=(p^relative)&255;
        end
    endfunction
    always @(negedge clk) begin
        sv=0;se=0;serr=0;
        if(rst) begin service=-1;sbusy=0;end
        else if(service>=0) begin
            if(service<(short_sector?511:512)) begin sd=disk(active_lba,service);sv=1;service=service+1;end
            else begin se=1;serr=corrupt;sbusy=0;service=-1;end
        end else if(sreq) begin
            service=0;active_lba=lba;sbusy=1;reads=reads+1;
            if(lba>=partition+32+fat_length*fats && lba<partition+32+fat_length*fats+sectors_per_cluster)
                root_reads=root_reads+1;
        end
    end
    always @(posedge clk) if(!rst) begin
        if(found) begin found_count=found_count+1;if(handle!=0 || total!=1) $fatal(1,"FAT catalog handle");end
        if(valid) begin
            if(data!==disk(partition+32+fat_length*fats+(address<sectors_per_cluster?3*sectors_per_cluster+address:7*sectors_per_cluster+address%sectors_per_cluster),received) && !raw_card) $fatal(1,"fragmented data mismatch %0d",received);
            received=received+1;
        end
    end
    task boot(input integer part);
        begin rst=1;init=0;partition=part;root_reads=0;repeat(4) @(negedge clk);rst=0;init=1;wait(mounted || fs_error!=0);end
    endtask
    task read_file(input integer offset,expect_error);
        begin
            wait(!busy);@(negedge clk);address=offset;received=0;req=1;
            @(negedge clk);req=0;wait(ending);@(negedge clk);
            if(error!=expect_error || received!=(expect_error?0:512)) $fatal(1,"file error/count %0d %0d",error,received);
        end
    endtask
    initial begin
        boot(0);if(fs_error || raw || !wav || wav_size!=1024) $fatal(1,"superfloppy mount error=%h state=%d cluster=%d max=%d wav=%b size=%d",fs_error,dut.state,dut.current_cluster,dut.max_cluster,wav,wav_size);
        @(negedge clk);cat=1;@(negedge clk);cat=0;wait(catdone);@(negedge clk);
        if(total!=1 || found_count!=1) $fatal(1,"root cluster-chain catalog");
        read_file(0,0);read_file(1,0);read_file(0,0);read_file(2,1);
        before_reads=reads;read_file(1,0);
        if(reads!=before_reads+1) $fatal(1,"cached FAT page reread: stereo bandwidth regression");
        corrupt=1;read_file(0,1);corrupt=0;read_file(0,0);
        short_sector=1;read_file(0,1);short_sector=0;
        read_file(32'hf0000000,1);
        boot(2048);if(fs_error || !wav) $fatal(1,"fourth MBR partition mount");
        read_file(0,0);read_file(1,0);
        short_chain=1;boot(0);read_file(1,1);short_chain=0;
        cycle=1;boot(0);read_file(3,1);cycle=0;
        root_cycle=1;boot(0);if(mounted || fs_error!=8'h24) $fatal(1,"root cycle accepted");root_cycle=0;
        fats=2;active_fat=1;boot(0);if(!mounted || fs_error) $fatal(1,"active FAT copy ignored");read_file(0,0);read_file(1,0);
        fats=1;active_fat=0;
        volume_length=500;boot(0);if(mounted || fs_error!=8'h21) $fatal(1,"metadata larger than volume accepted");
        volume_length=70000;fat_length=1;boot(0);if(mounted || fs_error!=8'h21) $fatal(1,"undersized FAT accepted");
        // An overallocated FAT is legal. Its capacity needs more than 33 bits.
        fat_length=67108864;volume_length=fat_length+70000;
        boot(0);if(!mounted || fs_error) $fatal(1,"large FAT capacity truncated");read_file(0,0);read_file(1,0);
        fat_length=600;volume_length=70000;
        // Every supported multi-sector cluster geometry must exhaust the root
        // cluster before following FAT, and file offsets must stay in-cluster.
        for(geometry=2;geometry<=128;geometry=geometry*2) begin
            sectors_per_cluster=geometry;volume_length=70000*geometry;
            boot(0);
            if(!mounted || fs_error || !wav || root_reads!=geometry)
                $fatal(1,"root boundary spc=%0d reads=%0d error=%h",geometry,root_reads,fs_error);
            read_file(0,0);read_file(1,0);
        end
        sectors_per_cluster=1;volume_length=70000;
        raw_card=1;boot(0);if(!raw) $fatal(1,"legacy raw card");read_file(0,0);
        raw_card=0;bad_bpb=1;boot(0);if(mounted || fs_error==0) $fatal(1,"unsupported BPB accepted");
        $display("PASS fat32_media: superfloppy/MBR4, root chain, fragmented file/rewind, bounds, corrupt sector discard, legacy raw");$finish;
    end
    initial begin #5000000;$fatal(1,"FAT watchdog state=%0d",dut.state);end
endmodule
