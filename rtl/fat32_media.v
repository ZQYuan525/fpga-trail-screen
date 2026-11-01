`timescale 1ns/1ps
// Read-only FAT32 catalog and sector address translation. Handles are file ID
// in bits 31:28 and file-relative sector in bits 27:0. IDs 0..3 are BMP, 4 WAV.
// Raw legacy cards beginning with BM remain readable. Never writes the card.
module fat32_media #(
    parameter integer MAX_DIRECTORY_SECTORS=4096, EARLY_CATALOG=0
)(
    input wire clk,rst,init_done,
    output reg mounted,raw_mode,
    output reg [7:0] fs_error,
    input wire catalog_start,
    input wire catalog_resume,
    output reg catalog_complete,
    output reg catalog_done,found_valid,
    output reg [31:0] found_handle,
    output reg [2:0] found_total,
    output reg wav_present,output reg [31:0] wav_size,
    input wire req,input wire [31:0] address,
    output wire busy,output reg [7:0] data,
    output reg valid,ending,error,
    output reg sector_req,output reg [31:0] sector_addr,
    input wire sector_busy,sector_valid,sector_end,sector_error,
    input wire [7:0] sector_data
);
    localparam WAIT_INIT=0,FETCH=1,RECEIVE=2,BOOT=3,LAYOUT=4,ROOT=5,
        DIRECTORY=6,DIRECTORY_NEXT=7,FAT_PARSE=8,IDLE=9,CATALOG=10,
        SEEK=11,DATA_ADDRESS=12,REPLAY=13,FINISH=14,FAILED=15,ADDRESS=16,REQUEST=17,CACHE_SELECT=18,TABLE_READ=19,FAT_ADDRESS=20,
        TABLE_WRITE=21,DIRECTORY_ADVANCE=22,BOOT_CHECK=23,LAYOUT_CHECK=24,
        FAT_CHECK=25,SEEK_CHECK=26,ROOT_CHECK=27,DIRECTORY_CHECK=28;
    reg [4:0] state,return_state;
    reg [1:0] layout_phase,address_phase;
    reg directory_paused,early_announced;
    reg [31:0] saved_directory_lba,saved_root_cluster,saved_anchor,saved_power,saved_span;
    reg [7:0] saved_root_sector;
    reg [4:0] saved_entry;
    reg [32:0] required_fat_entries;
    reg [3:0] layout_invalid;
    reg [32:0] overhead_q,volume_end_q,data_base_q;
    reg [31:0] data_sectors_q,clusters_q,cluster_minus,cluster_offset,cluster_lba;
    reg [7:0] sector_in_cluster;
    reg [4:0] address_return;
    (* ram_style="block" *) reg [7:0] buffer[0:511];
    (* ram_style="block" *) reg [7:0] fat_buffer[0:511];
    reg fat_cached;
    reg [31:0] fat_cached_lba;
    reg [31:0] fat_lba;
    reg [7:0] fat_byte_q;
    reg [7:0] boot_header[0:511]; // only the constant BPB/MBR fields below survive synthesis
    reg [9:0] count;
    reg boot_write;
    reg [8:0] boot_write_address;
    reg [7:0] boot_write_data;
    // Pipeline boot-header capture before its distributed byte enables.
    // RECEIVE consumes the ending cycle before BOOT examines these fields,
    // so even a final byte immediately followed by sector_end is committed.
    always @(posedge clk or posedge rst) begin
        if(rst) begin boot_write<=0;boot_write_address<=0;boot_write_data<=0;end
        else begin
            boot_write<=state==RECEIVE && sector_valid && count<512 && return_state==BOOT;
            boot_write_address<=count[8:0];boot_write_data<=sector_data;
        end
    end
    always @(posedge clk)
        if(boot_write) boot_header[boot_write_address]<=boot_write_data;
    reg [7:0] byte_q;
    reg byte_wait;
    reg [4:0] field_index;

    reg [8:0] pos;
    reg [4:0] entry;
    reg [2:0] image_count,replay_index,file_id;
    // {first cluster, byte size, cached cluster/index, Brent anchor/power/span}.
    // Catalog entries initialize whole records before their IDs become visible.
    // Fourteen 16-bit words per record fit the complete table in ONE 9-Kibit
    // RAM. A 224-bit-wide, eight-entry RAM wastes thirteen physical blocks.
    reg [15:0] file_table[0:127]; /* fehdl force_ram=1, ram_style="bram" */
    reg [15:0] table_word;
    reg [3:0] table_index;
    reg [4:0] table_return;
    // Requests are serialized: reuse the record shift register for writeback.
    reg [223:0] file_context;
    reg [2:0] table_write_address;
    reg boot_raw,boot_signature,boot_bpb,boot_fields_valid;
    reg fat_eof,fat_invalid,advance_anchor,seek_invalid,seek_at_target,root_invalid,entry_acceptable;
    reg [31:0] walk_anchor,walk_power,walk_span;
    reg invalid_handle,use_cached;
    reg [32:0] file_limit;
    reg [31:0] partition,partition_size,volume_sectors,fat_sectors,fat_base,data_base,max_cluster;
    reg [15:0] reserved;
    reg [7:0] spc,fat_count;
    reg [2:0] cluster_shift;
    reg [31:0] root_cluster,current_cluster,cluster_index,wanted_index,relative_sector;
    reg [7:0] root_sector;
    reg [31:0] directory_sectors;
    reg [8:0] fat_offset;
    reg partitioned,logical_read,root_walk;
    wire [8:0] entry_base={entry[3:0],5'b0};
    function [15:0] le16(input [8:0] offset);
        le16={boot_header[offset+1],boot_header[offset]};
    endfunction
    function [31:0] le32(input [8:0] offset);
        le32={boot_header[offset+3],boot_header[offset+2],boot_header[offset+1],boot_header[offset]};
    endfunction
    reg [31:0] next_cluster,entry_cluster,entry_size;
    reg [7:0] entry_first,entry_attr;
    reg [23:0] entry_extension;
    wire bmp_entry=entry_extension==24'h424d50;
    wire wav_entry=entry_extension==24'h574156;
    wire [8:0] read_pos=state==DIRECTORY?entry_base+field_index:state==FAT_PARSE?fat_offset+field_index:pos;
    wire [32:0] overhead={17'd0,reserved}+(fat_count==2?{fat_sectors,1'b0}:{1'b0,fat_sectors});
    wire [32:0] volume_end={1'b0,partition}+volume_sectors;
    wire [32:0] calculated_data={1'b0,partition}+overhead;
    wire [32:0] calculated_lba={1'b0,data_base}+(({1'b0,current_cluster}-2)<<cluster_shift);
    wire [32:0] file_sectors=({1'b0,file_context[191:160]}+511)>>9;
    assign busy=state!=IDLE;
    integer i;
    task fail(input [7:0] code);
        begin
            fs_error<=code;
            if(logical_read) begin error<=1;state<=FINISH;end
            else begin mounted<=0;state<=FAILED;end
        end
    endtask
    task fetch(input [31:0] lba,input [4:0] next_state);
        begin sector_addr<=lba;return_state<=next_state;state<=FETCH;end
    endtask
    task follow_fat;
        begin
            fat_offset<={current_cluster[6:0],2'b0};field_index<=0;
            fat_lba<=fat_base+(current_cluster>>7);
            state<=FAT_ADDRESS;
        end
    endtask
    always @(posedge clk) begin
        if(state==TABLE_WRITE) file_table[{table_write_address,table_index}]<=file_context[15:0];
        table_word<=file_table[{file_id,table_index}];
        if(state==RECEIVE && sector_valid && count<512) begin
            buffer[count[8:0]]<=sector_data;
            if(return_state==FAT_PARSE) fat_buffer[count[8:0]]<=sector_data;
        end
        byte_q<=buffer[read_pos];
        fat_byte_q<=fat_buffer[fat_offset+field_index];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=WAIT_INIT;return_state<=BOOT;mounted<=0;raw_mode<=0;fs_error<=0;
            catalog_complete<=0;directory_paused<=0;early_announced<=0;
            saved_directory_lba<=0;saved_root_cluster<=0;saved_anchor<=0;saved_power<=0;saved_span<=0;
            saved_root_sector<=0;saved_entry<=0;
            layout_phase<=0;address_phase<=0;overhead_q<=0;volume_end_q<=0;data_base_q<=0;
            required_fat_entries<=0;layout_invalid<=0;
            data_sectors_q<=0;clusters_q<=0;cluster_minus<=0;cluster_offset<=0;cluster_lba<=0;sector_in_cluster<=0;address_return<=0;
            fat_cached<=0;fat_cached_lba<=0;fat_lba<=0;walk_anchor<=0;walk_power<=1;walk_span<=0;
            invalid_handle<=0;use_cached<=0;file_limit<=0;
            table_index<=0;table_return<=0;file_context<=0;table_write_address<=0;
            boot_raw<=0;boot_signature<=0;boot_bpb<=0;boot_fields_valid<=0;
            fat_eof<=0;fat_invalid<=0;advance_anchor<=0;seek_invalid<=0;seek_at_target<=0;root_invalid<=0;entry_acceptable<=0;
            byte_wait<=0;field_index<=0;next_cluster<=0;entry_cluster<=0;entry_size<=0;entry_first<=0;entry_attr<=0;entry_extension<=0;
            catalog_done<=0;found_valid<=0;found_handle<=0;found_total<=0;
            wav_present<=0;wav_size<=0;data<=0;valid<=0;ending<=0;error<=0;sector_req<=0;sector_addr<=0;
            count<=0;pos<=0;entry<=0;image_count<=0;replay_index<=0;file_id<=0;
            partition<=0;partition_size<=0;volume_sectors<=0;fat_sectors<=0;fat_base<=0;data_base<=0;max_cluster<=0;
            reserved<=0;spc<=0;fat_count<=0;cluster_shift<=0;root_cluster<=0;current_cluster<=0;
            cluster_index<=0;wanted_index<=0;relative_sector<=0;root_sector<=0;directory_sectors<=0;
            fat_offset<=0;partitioned<=0;logical_read<=0;root_walk<=0;
        end else begin
            sector_req<=0;valid<=0;ending<=0;found_valid<=0;catalog_done<=0;
            if((state==DIRECTORY || state==FAT_PARSE || state==REPLAY || state==TABLE_READ) && !byte_wait) byte_wait<=1;
            else begin
            byte_wait<=0;
            case(state)
                WAIT_INIT: if(init_done) fetch(0,BOOT);
                FETCH: if(!sector_busy) begin count<=0;sector_req<=1;state<=RECEIVE;if(return_state==FAT_PARSE) fat_cached<=0;end
                RECEIVE: begin
                    if(sector_valid && count<513) count<=count+1'b1;
                    if(sector_end) begin
                        if(sector_error || count!=512) fail(8'h10);
                        else begin
                            pos<=0;field_index<=0;state<=return_state;
                            if(return_state==FAT_PARSE) begin fat_cached<=1;fat_cached_lba<=sector_addr;end
                        end
                    end
                end
                BOOT: begin
                    // Register format checks before selecting a mount action;
                    // do not put header validation and request enables on one path.
                    boot_raw<=boot_header[0]=="B" && boot_header[1]=="M";
                    boot_signature<=le16(510)==16'haa55;
                    boot_bpb<=le16(11)==512 && le16(17)==0 && le16(22)==0 && le32(36)!=0;
                    boot_fields_valid<=boot_header[13]!=0 && (boot_header[13]&(boot_header[13]-1))==0 && le16(14)!=0 &&
                        (boot_header[16]==1 || boot_header[16]==2) && le16(42)==0 &&
                        ((boot_header[40]&8'h80)==0 || (boot_header[40]&8'h0f)<boot_header[16]);
                    state<=BOOT_CHECK;
                end
                BOOT_CHECK: begin
                    if(!partitioned && boot_raw) begin raw_mode<=1;mounted<=1;catalog_complete<=1;state<=IDLE;end
                    else if(!boot_signature) begin
                        if(!partitioned) begin raw_mode<=1;mounted<=1;catalog_complete<=1;state<=IDLE;end
                        else fail(8'h20);
                    end
                    else if(boot_bpb) begin
                        reserved<=le16(14);spc<=boot_header[13];fat_count<=boot_header[16];fat_sectors<=le32(36);
                        volume_sectors<=le32(32);root_cluster<=le32(44)&32'h0fffffff;
                        case(boot_header[13])
                            1:cluster_shift<=0;2:cluster_shift<=1;4:cluster_shift<=2;8:cluster_shift<=3;
                            16:cluster_shift<=4;32:cluster_shift<=5;64:cluster_shift<=6;128:cluster_shift<=7;
                            default:cluster_shift<=0;
                        endcase
                        // FAT mirroring disabled: honor the selected FAT copy.
                        fat_base<=partition+le16(14)+((boot_header[40]&8'h81)==8'h81 ? le32(36):0);
                        if(!boot_fields_valid) fail(8'h21);
                        else begin layout_phase<=0;state<=LAYOUT;end
                    end else if(!partitioned) begin
                        if(boot_header[450]==8'h0b || boot_header[450]==8'h0c) begin
                            partition<=le32(454);partition_size<=le32(458);partitioned<=1;fetch(le32(454),BOOT);
                        end else if(boot_header[466]==8'h0b || boot_header[466]==8'h0c) begin
                            partition<=le32(470);partition_size<=le32(474);partitioned<=1;fetch(le32(470),BOOT);
                        end else if(boot_header[482]==8'h0b || boot_header[482]==8'h0c) begin
                            partition<=le32(486);partition_size<=le32(490);partitioned<=1;fetch(le32(486),BOOT);
                        end else if(boot_header[498]==8'h0b || boot_header[498]==8'h0c) begin
                            partition<=le32(502);partition_size<=le32(506);partitioned<=1;fetch(le32(502),BOOT);
                        end else fail(8'h21);
                    end else fail(8'h21);
                end
                LAYOUT: begin
                    layout_phase<=layout_phase+1'b1;
                    case(layout_phase)
                    0:begin overhead_q<=overhead;volume_end_q<=volume_end;end
                    1:begin data_base_q<={1'b0,partition}+overhead_q;data_sectors_q<=volume_sectors-overhead_q;end
                    2:clusters_q<=data_sectors_q>>cluster_shift;
                    3:begin
                    data_base<=data_base_q[31:0];max_cluster<=clusters_q+1;
                    required_fat_entries<={1'b0,clusters_q}+2;
                    layout_invalid[0]<=volume_end_q[32] || data_base_q[32] || overhead_q>=volume_sectors;
                    layout_invalid[1]<=partitioned && (partition==0 || volume_sectors>partition_size);
                    layout_invalid[2]<=clusters_q<65525 || clusters_q>32'h0fffffee;
                    state<=LAYOUT_CHECK;
                    end
                    endcase
                end
                LAYOUT_CHECK: begin
                    // Separate arithmetic, comparison, then control fanout.
                    // Compare at full width; large valid FATs must not wrap.
                    if(layout_phase==0) begin
                        layout_invalid[3]<={fat_sectors,7'b0}<required_fat_entries;
                        layout_phase<=1;
                    end else if(|layout_invalid) fail(8'h21);
                    else begin current_cluster<=root_cluster;walk_anchor<=root_cluster;walk_power<=1;walk_span<=0;root_walk<=1;state<=ROOT;end
                end
                ROOT: begin
                    root_invalid<=current_cluster<2 || current_cluster>max_cluster || directory_sectors>=MAX_DIRECTORY_SECTORS;
                    cluster_minus<=current_cluster-2;sector_in_cluster<=root_sector;
                    state<=ROOT_CHECK;
                end
                ROOT_CHECK: begin
                    if(root_invalid) fail(8'h24);
                    else begin
                        entry<=0;directory_sectors<=directory_sectors+1;
                        address_phase<=0;address_return<=DIRECTORY;state<=ADDRESS;
                    end
                end
                DIRECTORY: if(field_index!=31) begin
                    field_index<=field_index+1'b1;
                    case(field_index)
                        0:entry_first<=byte_q;8:entry_extension[23:16]<=byte_q;9:entry_extension[15:8]<=byte_q;10:entry_extension[7:0]<=byte_q;
                        11:entry_attr<=byte_q;20:entry_cluster[23:16]<=byte_q;21:entry_cluster[31:24]<={4'd0,byte_q[3:0]};
                        26:entry_cluster[7:0]<=byte_q;27:entry_cluster[15:8]<=byte_q;
                        28:entry_size[7:0]<=byte_q;29:entry_size[15:8]<=byte_q;30:entry_size[23:16]<=byte_q;
                    endcase
                end else begin
                    field_index<=0;
                    entry_size[31:24]<=byte_q;
                    entry_acceptable<=entry_first!=8'he5 && (entry_attr&8'h18)==0 &&
                        entry_attr!=8'h0f && entry_cluster>=2 && entry_cluster<=max_cluster && {byte_q,entry_size[23:0]}!=0;
                    state<=DIRECTORY_CHECK;
                end
                DIRECTORY_CHECK: begin
                    if(entry_first==0) begin
                        mounted<=1;catalog_complete<=!EARLY_CATALOG;
                        if(EARLY_CATALOG && early_announced) begin replay_index<=0;state<=CATALOG;end
                        else state<=IDLE;
                    end
                    else begin
                        state<=DIRECTORY_ADVANCE;
                        if(entry_acceptable) begin
                            if(bmp_entry && image_count<4) begin
                                state<=TABLE_WRITE;table_return<=DIRECTORY_ADVANCE;table_index<=0;table_write_address<=image_count;
                                file_context<={entry_cluster,entry_size,entry_cluster,32'd0,entry_cluster,32'd1,32'd0};
                                image_count<=image_count+1'b1;
                            end else if(wav_entry && !wav_present) begin
                                state<=TABLE_WRITE;table_return<=DIRECTORY_ADVANCE;table_index<=0;table_write_address<=4;
                                file_context<={entry_cluster,entry_size,entry_cluster,32'd0,entry_cluster,32'd1,32'd0};
                                wav_present<=1;wav_size<=entry_size;
                            end
                        end
                    end
                end
                DIRECTORY_ADVANCE: begin
                    // Pause exactly once, after the first file record is committed.
                    // File reads may overwrite both sector buffers and traversal registers;
                    // save the directory walk and re-fetch its sector when resuming.
                    if(EARLY_CATALOG && image_count!=0 && !early_announced) begin
                        saved_directory_lba<=sector_addr;saved_root_cluster<=current_cluster;
                        saved_root_sector<=root_sector;saved_entry<=entry;
                        saved_anchor<=walk_anchor;saved_power<=walk_power;saved_span<=walk_span;
                        early_announced<=1;directory_paused<=1;mounted<=1;state<=IDLE;
                    end else if(entry==15) state<=DIRECTORY_NEXT;
                    else begin entry<=entry+1'b1;state<=DIRECTORY;end
                end
                DIRECTORY_NEXT: begin
                    if(root_sector+1<spc) begin root_sector<=root_sector+1'b1;state<=ROOT;end
                    else follow_fat();
                end
                FAT_ADDRESS: begin
                    if(fat_cached && fat_cached_lba==fat_lba) state<=FAT_PARSE;
                    else fetch(fat_lba,FAT_PARSE);
                end
                FAT_PARSE: if(field_index<4) begin
                    field_index<=field_index+1'b1;
                    case(field_index)
                        0:next_cluster[7:0]<=fat_byte_q;1:next_cluster[15:8]<=fat_byte_q;2:next_cluster[23:16]<=fat_byte_q;
                        3:next_cluster[31:24]<={4'd0,fat_byte_q[3:0]};
                    endcase
                end else begin
                    field_index<=0;
                    fat_eof<=root_walk && next_cluster>=32'h0ffffff8;
                    fat_invalid<=next_cluster<2 || next_cluster>max_cluster || next_cluster==current_cluster || next_cluster==walk_anchor;
                    advance_anchor<=walk_span+1==walk_power;
                    state<=FAT_CHECK;
                end
                FAT_CHECK: begin
                    if(fat_eof) begin
                        mounted<=1;catalog_complete<=!EARLY_CATALOG;
                        if(EARLY_CATALOG && early_announced) begin replay_index<=0;state<=CATALOG;end
                        else state<=IDLE;
                    end
                    else if(fat_invalid) fail(8'h24);
                    else begin
                        // Brent cycle detection survives sequential requests via each file's cache.
                        if(advance_anchor) begin walk_anchor<=next_cluster;walk_power<=walk_power<<1;walk_span<=0;end
                        else walk_span<=walk_span+1;
                        current_cluster<=next_cluster;cluster_index<=cluster_index+1;
                        if(root_walk) begin root_sector<=0;state<=ROOT;end else state<=SEEK;
                    end
                end
                IDLE: begin
                    logical_read<=0;
                    if(catalog_start) begin replay_index<=0;found_total<=0;state<=CATALOG;end
                    else if(EARLY_CATALOG && directory_paused && catalog_resume && !req) begin
                        directory_paused<=0;root_walk<=1;current_cluster<=saved_root_cluster;
                        root_sector<=saved_root_sector;entry<=saved_entry;
                        walk_anchor<=saved_anchor;walk_power<=saved_power;walk_span<=saved_span;
                        fetch(saved_directory_lba,DIRECTORY_ADVANCE);
                    end else if(req) begin
                        logical_read<=1;error<=0;fs_error<=0;root_walk<=0;
                        file_id<=address[30:28];relative_sector<={4'd0,address[27:0]};table_index<=0;
                        wanted_index<=address[27:0]>>cluster_shift;
                        invalid_handle<=address[31:28]>4;
                        if(raw_mode) fetch(address,REPLAY);
                        else state<=TABLE_READ;
                    end
                end
                TABLE_READ: begin
                    file_context<={table_word,file_context[223:16]};
                    if(table_index==13) begin table_index<=0;state<=REQUEST;end
                    else table_index<=table_index+1'b1;
                end
                TABLE_WRITE: begin
                    file_context<=file_context>>16;
                    if(table_index==13) begin table_index<=0;state<=table_return;end
                    else table_index<=table_index+1'b1;
                end
                REQUEST: begin
                    if(invalid_handle || (file_id<4 && file_id>=image_count) || (file_id==4 && !wav_present)) fail(8'h25);
                    else begin
                        file_limit<=file_sectors;
                        use_cached<=wanted_index>=file_context[127:96];state<=CACHE_SELECT;
                    end
                end
                CACHE_SELECT: begin
                    if(use_cached) begin
                        current_cluster<=file_context[159:128];cluster_index<=file_context[127:96];
                        walk_anchor<=file_context[95:64];walk_power<=file_context[63:32];walk_span<=file_context[31:0];
                    end else begin
                        current_cluster<=file_context[223:192];cluster_index<=0;walk_anchor<=file_context[223:192];walk_power<=1;walk_span<=0;
                    end
                    state<=SEEK;
                end
                CATALOG: if(replay_index<image_count) begin
                    found_handle<={1'b0,replay_index,28'd0};found_valid<=1;
                    found_total<=replay_index+1'b1;replay_index<=replay_index+1'b1;
                end else begin catalog_done<=1;catalog_complete<=!directory_paused;state<=IDLE;end
                SEEK: begin
                    seek_invalid<=relative_sector>=file_limit || current_cluster<2 || current_cluster>max_cluster || cluster_index>max_cluster;
                    seek_at_target<=cluster_index==wanted_index;
                    state<=SEEK_CHECK;
                end
                SEEK_CHECK: begin
                    if(seek_invalid) fail(8'h25);
                    else if(seek_at_target) state<=DATA_ADDRESS;
                    else follow_fat();
                end
                DATA_ADDRESS: begin
                    table_write_address<=file_id;table_index<=0;table_return<=ADDRESS;
                    file_context<={file_context[223:160],current_cluster,cluster_index,walk_anchor,walk_power,walk_span};
                    cluster_minus<=current_cluster-2;sector_in_cluster<=relative_sector&(spc-1);
                    address_phase<=0;address_return<=REPLAY;state<=TABLE_WRITE;
                end
                ADDRESS: begin
                    address_phase<=address_phase+1'b1;
                    case(address_phase)
                        0:cluster_offset<=cluster_minus<<cluster_shift;
                        1:cluster_lba<=data_base+cluster_offset;
                        2:fetch(cluster_lba+sector_in_cluster,address_return);
                    endcase
                end
                REPLAY: begin
                    data<=byte_q;valid<=1;
                    if(pos==511) state<=FINISH;else pos<=pos+1'b1;
                end
                FINISH: begin ending<=1;state<=IDLE;end
                FAILED: state<=FAILED;
                default: state<=WAIT_INIT;
            endcase
            end
        end
    end
endmodule
