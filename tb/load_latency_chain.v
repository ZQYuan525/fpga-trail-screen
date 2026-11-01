`timescale 1ns/1ps
// Reset -> first-image publish latency on the production
// SD/FAT32/BMP/scaler/player RTL, wired as in top.v (filesystem, extensions,
// WAV idle before preload). The card serves the real acceptance FAT32 image.
// The SDRAM writer and display are stubs (always ready, immediate ack): their
// latency (a few us, <= one 59.5 Hz frame for publish) is added analytically.
// MAX_DATA_SECTORS>0 stops after that many pixel sectors past the header, for
// measured-per-sector extrapolation; 0 runs the complete first-image load.
// REAL_INIT=1 uses top.v's init timing (100 ms power/retry wait, 8192-byte
// 200 kHz drain); otherwise init is shortened and measured from init_done.
module load_latency_chain #(
    parameter integer DIV=25, FIRST_ENTRY=0, MAX_DATA_SECTORS=0, NAC_BYTES=0,
    parameter integer REAL_INIT=0, ACMD41_BUSY=2,
    parameter integer EXP_W=1280, EXP_H=960, EXP_SECTORS=7201
)(output reg finished);
    localparam integer OUT_PIXELS=640*480;
    localparam real SPI_SECTOR_NS=(524.0+NAC_BYTES)*(16*DIV+2)*10.0;
    reg clk=0,rst=0;
    initial finished=0;
    always #5 if(!finished) clk=~clk;

    wire init_start,init_selected,sd_init_done,sd_block,spi_busy,spi_done;
    wire [7:0] init_tx,sector_tx,spi_rx;
    wire [3:0] init_error;
    wire card_req,card_busy,card_valid,card_end,card_error,sector_selected,sector_start;
    wire [31:0] card_addr;
    wire [7:0] card_data;
    wire [11:0] read_diagnostic;
    wire sck,cs,mosi,miso;
    generate if(REAL_INIT) begin: g_init
        sd_init_seq #(.POWER_WAIT(100_000_000/10)) init(.clk(clk),.rst(rst),.spi_start(init_start),.spi_byte(init_tx),
            .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx),.selected(init_selected),
            .init_done(sd_init_done),.init_busy(),.block_addressing(sd_block),.err_code(init_error),.command_diagnostic());
    end else begin: g_init
        sd_init_seq #(.POWER_WAIT(10),.RECOVERY_BYTES(16)) init(.clk(clk),.rst(rst),.spi_start(init_start),.spi_byte(init_tx),
            .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx),.selected(init_selected),
            .init_done(sd_init_done),.init_busy(),.block_addressing(sd_block),.err_code(init_error),.command_diagnostic());
    end endgenerate
    sd_rw_sector #(.TOKEN_TIMEOUT(100_000_000/(16*DIV)/10+1)) u_sector(.clk(clk),.rst(rst),.sec_read(card_req),.sec_addr(card_addr),
        .block_addressing(sd_block),.sec_data(card_data),.sec_data_valid(card_valid),.sec_end(card_end),
        .sec_error(card_error),.read_diagnostic(read_diagnostic),.busy(card_busy),.selected(sector_selected),
        .spi_start(sector_start),.spi_byte(sector_tx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx));
    sd_spi #(.DIV(DIV)) u_spi(.clk(clk),.rst(rst),.selected(sd_init_done?sector_selected:init_selected),.low_speed(!sd_init_done),
        .spi_start(sd_init_done?sector_start:init_start),.spi_byte(sd_init_done?sector_tx:init_tx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx),.sck(sck),.cs(cs),.mosi(mosi),.miso(miso));
    integer commands,fat_reads,data_reads,preclocks;
    wire [31:0] card_lba;
    sd_image_card_model #(.FIRST_ENTRY(FIRST_ENTRY),.NAC_BYTES(NAC_BYTES),.ACMD41_BUSY(ACMD41_BUSY)) card(
        .rst(rst),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),.command17_count(commands),
        .fat_reads(fat_reads),.data_reads(data_reads),.preclocks(preclocks),.last_lba(card_lba));

    // top.v filesystem generate branch; wav_owner stays 0 until preload_done.
    wire sector_req,sector_busy,sector_valid,sector_end,sector_error;
    wire [31:0] sector_addr;
    wire [7:0] sector_data;
    wire fs_mounted,fs_raw,fs_scan_done,fs_found,fs_catalog_complete,catalog_continue;
    wire [31:0] fs_handle;
    wire [2:0] fs_total;
    wire [7:0] fs_error;
    wire scan_start,load_start,load_abort;
    fat32_media #(.EARLY_CATALOG(1)) u_fs(.catalog_resume(catalog_continue),.catalog_complete(fs_catalog_complete),.clk(clk),.rst(rst),.init_done(sd_init_done),
        .mounted(fs_mounted),.raw_mode(fs_raw),.fs_error(fs_error),
        .catalog_start(scan_start && !fs_raw),.catalog_done(fs_scan_done),.found_valid(fs_found),
        .found_handle(fs_handle),.found_total(fs_total),.wav_present(),.wav_size(),
        .req(sector_req),.address(sector_addr),.busy(sector_busy),.data(sector_data),
        .valid(sector_valid),.ending(sector_end),.error(sector_error),
        .sector_req(card_req),.sector_addr(card_addr),.sector_busy(card_busy),.sector_valid(card_valid),
        .sector_end(card_end),.sector_error(card_error),.sector_data(card_data));

    wire bmp_ready,bmp_scan_done,bmp_found,bmp_req,bmp_ack,px_valid,px_ready,load_done,load_error,bmp_progress;
    wire [31:0] bmp_found_sector,load_sector;
    wire [2:0] bmp_found_total;
    wire [23:0] px_data;
    wire [3:0] bmp_state;
    wire [15:0] source_width,source_height;
    wire scan_done=fs_raw?bmp_scan_done:fs_scan_done;
    wire found=fs_raw?bmp_found:fs_found;
    wire [31:0] found_sector=fs_raw?bmp_found_sector:fs_handle;
    wire [2:0] found_total=fs_raw?bmp_found_total:fs_total;
    bmp_decoder #(.FLEXIBLE_SIZE(1)) u_bmp(.clk(clk),.rst(rst),.sd_init_done(sd_init_done && fs_mounted),.ready(bmp_ready),
        .sd_sec_read(sector_req),.sd_sec_addr(sector_addr),.sd_sec_data(sector_data),
        .sd_sec_data_valid(sector_valid),.sd_sec_end(sector_end),.sd_sec_busy(sector_busy),.sd_sec_error(sector_error),
        .bmp_width(16'd1280),.bmp_height(16'd960),.scan_start(scan_start && fs_raw),.scan_done(bmp_scan_done),
        .scan_found_valid(bmp_found),.scan_found_sector(bmp_found_sector),.scan_found_total(bmp_found_total),
        .load_start(load_start),.load_abort(load_abort),.load_sector(load_sector),
        .write_req(bmp_req),.write_req_ack(bmp_ack),.px_wr_en(px_valid),.px_data(px_data),.px_ready(px_ready),
        .load_done(load_done),.load_error(load_error),.progress(bmp_progress),.state_code(bmp_state),
        .source_width(source_width),.source_height(source_height),.source_top_down());
    wire scaled_valid,scaled_ready,scaled_done,scaled_error,scaler_idle;
    wire [23:0] scaled_data;
    reg bmp_req_d;
    always @(posedge clk or posedge rst) if(rst) bmp_req_d<=0;else bmp_req_d<=bmp_req;
    bilinear_scaler u_scale(.clk(clk),.rst(rst),.start(bmp_req && !bmp_req_d),.abort_load(load_abort),
        .source_width(source_width),.source_height(source_height),.in_valid(px_valid),.in_data(px_data),.in_ready(px_ready),
        .in_done(load_done),.in_error(load_error),.out_valid(scaled_valid),.out_data(scaled_data),.out_ready(scaled_ready),
        .done(scaled_done),.error(scaled_error),.idle(scaler_idle));

    wire write_req,write_en,write_abort,publish_req,player_error;
    reg write_ack,write_abort_ack,publish_ack,finish_toggle;
    integer pixels_written;
    sd_player #(.DIRECT_SELECT(1),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),.RETRY_INPUT(1),.SKIP_BAD(1),.STREAM_CATALOG(1)) u_player(
        .clk(clk),.rst(rst),.retry_load(1'b0),.key_next(1'b0),.key_auto(1'b0),.sd_init_done(sd_init_done),
        .display_valid(),.state_code(),.write_finish_t(finish_toggle),
        .key_prev(1'b0),.period_select(2'd0),.select_request(1'b0),.select_index(2'd0),.browse_active(1'b0),
        .cached_slots(),.catalog_slots(),.control_busy(),.current_image(),.target_image(),.auto_enabled(),
        .write_req(write_req),.write_req_ack(write_ack),.write_en(write_en),.write_data(),.write_ready(1'b1),
        .write_buf_idx(),.disp_buf_idx(),.bmp_write_req(bmp_req),.bmp_write_req_ack(bmp_ack),
        .scan_start(scan_start),.load_start(load_start),.load_sector(load_sector),.bmp_ready(bmp_ready && scaler_idle),
        .scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(found_total),
        .load_abort(load_abort),.bmp_px_wr_en(scaled_valid),.bmp_px_data(scaled_data),.bmp_px_ready(scaled_ready),
        .bmp_load_done(scaled_done || (load_done && load_error)),.bmp_load_error(scaled_error || load_error),
        .bmp_progress(bmp_progress || (scaled_valid && scaled_ready)),
        .write_abort(write_abort),.write_abort_ack(write_abort_ack),
        .publish_req(publish_req),.publish_ack(publish_ack),.publish_fade(),.error(player_error),.load_success(),.preload_done(),
        .catalog_complete(fs_raw?1'b1:fs_catalog_complete),.catalog_continue(catalog_continue),.bad_slots());
    // Memory/display stubs: level handshakes echo on the next clock.
    always @(posedge clk or posedge rst)
        if(rst) begin write_ack<=0;write_abort_ack<=0;publish_ack<=0;finish_toggle<=0;pixels_written<=0;end
        else begin
            write_ack<=write_req;write_abort_ack<=write_abort;publish_ack<=publish_req;
            if(write_req && !write_ack) pixels_written<=0;
            else if(write_en) begin
                pixels_written<=pixels_written+1;
                if(pixels_written==OUT_PIXELS-1) finish_toggle<=~finish_toggle;
            end
        end

    // ---------------- measurement ----------------
    realtime t_rel,t_pre,t_drain,t_cmd,t_init,t_mount,t_scan_start,t_scan_done,t_load_start;
    realtime t_hdr,t_prev,t_last,t_load_done,t_pub,t_first_pixel;
    real pure_sum,fat_gap_sum;
    integer pure_n,fat_gap_n,data_after_hdr,load_fat,load_data,mount_reads,retry_waits,init_cmds;
    reg [31:0] req_lba;
    reg fat_since_prev,in_load,hdr_seen,pub_seen,px_seen,stop_now;
    reg [3:0] init_state_d;
    wire [3:0] init_state=g_init.init.state;
    initial begin
        t_pre=0;t_drain=0;t_cmd=0;t_init=0;t_mount=0;t_scan_start=0;t_scan_done=0;t_load_start=0;
        t_hdr=0;t_prev=0;t_last=0;t_load_done=0;t_pub=0;t_first_pixel=0;
        pure_sum=0;fat_gap_sum=0;pure_n=0;fat_gap_n=0;data_after_hdr=0;load_fat=0;load_data=0;
        mount_reads=0;retry_waits=0;init_cmds=0;req_lba=0;fat_since_prev=0;in_load=0;hdr_seen=0;
        pub_seen=0;px_seen=0;stop_now=0;init_state_d=0;
    end
    always @(posedge clk) if(!rst) begin
        init_state_d<=init_state;
        if(init_state!=init_state_d) begin
            if(init_state==1 && t_pre==0) t_pre=$realtime;
            if(init_state==9 && t_drain==0) t_drain=$realtime;
            if(init_state==3) begin if(t_cmd==0) t_cmd=$realtime;init_cmds=init_cmds+1;end
            if(init_state==7) retry_waits=retry_waits+1;
        end
        if(sd_init_done && t_init==0) t_init=$realtime;
        if(fs_mounted && t_mount==0) begin t_mount=$realtime;mount_reads=commands;end
        if(scan_start && t_scan_start==0) t_scan_start=$realtime;
        if(scan_done && t_scan_done==0) t_scan_done=$realtime;
        if(load_start && !in_load) begin in_load=1;t_load_start=$realtime;end
        if(scaled_valid && scaled_ready && !px_seen) begin px_seen=1;t_first_pixel=$realtime;end
        if(card_req) req_lba<=card_addr;
        if(card_end && in_load && !pub_seen) begin
            if(req_lba>=card.reserved && req_lba<card.fat_end) begin load_fat=load_fat+1;fat_since_prev=1;end
            else begin
                load_data=load_data+1;
                if(!hdr_seen) begin hdr_seen=1;t_hdr=$realtime;end
                else begin
                    data_after_hdr=data_after_hdr+1;
                    if(fat_since_prev) begin fat_gap_sum=fat_gap_sum+($realtime-t_prev);fat_gap_n=fat_gap_n+1;end
                    else begin pure_sum=pure_sum+($realtime-t_prev);pure_n=pure_n+1;end
                end
                t_prev=$realtime;t_last=$realtime;fat_since_prev=0;
                if(MAX_DATA_SECTORS!=0 && data_after_hdr==MAX_DATA_SECTORS) stop_now=1;
            end
        end
        if(scaled_done && t_load_done==0) t_load_done=$realtime;
        if(publish_req && !pub_seen) begin pub_seen=1;t_pub=$realtime;end
        if(init_error!=0 || fs_error!=0 || player_error || load_error || scaled_error || card_error)
            $fatal(1,"DIV=%0d entry=%0d chain error init=%h fs=%h player=%b load=%b scale=%b card=%b detail=%h",
                DIV,FIRST_ENTRY,init_error,fs_error,player_error,load_error,scaled_error,card_error,read_diagnostic);
    end
    task report;
        real pure_ms,t_spi_ms;
        begin
            pure_ms=pure_n?pure_sum/pure_n/1e6:0;t_spi_ms=SPI_SECTOR_NS/1e6;
            if(source_width!=EXP_W || source_height!=EXP_H)
                $fatal(1,"DIV=%0d entry=%0d first image %0dx%0d, expected %0dx%0d",DIV,FIRST_ENTRY,source_width,source_height,EXP_W,EXP_H);
            if(pure_n<8) $fatal(1,"DIV=%0d entry=%0d too few pure sector intervals (%0d)",DIV,FIRST_ENTRY,pure_n);
            // The SPI bit time is a hard floor; the store-and-forward chain adds to it.
            if(pure_ms<t_spi_ms*0.995) $fatal(1,"DIV=%0d per-sector %.4f ms below SPI floor %.4f ms",DIV,pure_ms,t_spi_ms);
            if(EXP_W>=640 && pure_ms>t_spi_ms*1.25+0.05)
                $fatal(1,"DIV=%0d per-sector %.4f ms exceeds 1.25x SPI %.4f ms: unexpected stall",DIV,pure_ms,t_spi_ms);
            if(MAX_DATA_SECTORS==0) begin
                if(!pub_seen || load_data!=EXP_SECTORS || pixels_written!=OUT_PIXELS)
                    $fatal(1,"DIV=%0d entry=%0d incomplete: publish=%b data=%0d/%0d pixels=%0d",
                        DIV,FIRST_ENTRY,pub_seen,load_data,EXP_SECTORS,pixels_written);
            end else if(data_after_hdr!=MAX_DATA_SECTORS) $fatal(1,"DIV=%0d truncated window mismatch",DIV);
            $display("T08LAT div=%0d entry=%0d nac=%0d real_init=%0d full=%0d w=%0d h=%0d t_pre_ms=%.6f t_drain_ms=%.6f t_cmd_ms=%.6f t_init_ms=%.6f retry_waits=%0d init_cmds=%0d t_mount_ms=%.6f mount_reads=%0d t_scan_start_ms=%.6f t_scan_done_ms=%.6f t_load_start_ms=%.6f t_hdr_ms=%.6f t_first_pixel_ms=%.6f t_last_ms=%.6f t_load_done_ms=%.6f t_pub_ms=%.6f load_data=%0d load_fat=%0d data_after_hdr=%0d pure_n=%0d pure_ms=%.6f fat_gap_n=%0d fat_gap_ms=%.6f spi_floor_ms=%.6f pixels=%0d cmd17=%0d",
                DIV,FIRST_ENTRY,NAC_BYTES,REAL_INIT,MAX_DATA_SECTORS==0,source_width,source_height,
                t_pre/1e6,t_drain/1e6,t_cmd/1e6,t_init/1e6,retry_waits,init_cmds,t_mount/1e6,mount_reads,
                t_scan_start/1e6,t_scan_done/1e6,t_load_start/1e6,t_hdr/1e6,t_first_pixel/1e6,t_last/1e6,
                t_load_done/1e6,t_pub/1e6,load_data,load_fat,data_after_hdr,pure_n,pure_ms,
                fat_gap_n,fat_gap_n?fat_gap_sum/fat_gap_n/1e6:0.0,t_spi_ms,pixels_written,commands);
        end
    endtask
    initial begin
        #11;rst=1;repeat(8) @(negedge clk);rst=0;t_rel=$realtime;
        // All times are reported relative to reset release (t_rel is 91 ns).
        if(MAX_DATA_SECTORS==0) wait(pub_seen);else wait(stop_now);
        repeat(2) @(posedge clk);
        t_pre=t_pre-t_rel;t_drain=t_drain-t_rel;t_cmd=t_cmd-t_rel;t_init=t_init-t_rel;t_mount=t_mount-t_rel;
        t_scan_start=t_scan_start-t_rel;t_scan_done=t_scan_done-t_rel;t_load_start=t_load_start-t_rel;
        t_hdr=t_hdr-t_rel;t_first_pixel=t_first_pixel-t_rel;t_last=t_last-t_rel;
        if(t_load_done!=0) t_load_done=t_load_done-t_rel;
        if(t_pub!=0) t_pub=t_pub-t_rel;
        report;
        finished=1;
    end
endmodule
