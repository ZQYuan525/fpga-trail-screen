`timescale 1ns/1ps
// HX4S20 fixed 640x480 player. Real board IP lives in ../ip; never build in place.
module top #(
    parameter integer DIAG_MODE = 0,
    parameter integer ENABLE_EXTENSIONS = 1,
    parameter integer ENABLE_FILESYSTEM = 1,
    parameter integer ENABLE_PERSISTENCE = 0,
    parameter integer SD_SPI_DIV = 5
)(
    input wire clk,rst_n,key1,key2,key3,input wire [1:0] sw,
    output wire [3:0] led,output wire buzzer,
    output wire [5:0] seg_sel,output wire [7:0] seg_data,
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,
    output wire HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
    output wire sd_ncs,sd_dclk,sd_mosi,input wire sd_miso,
    output wire flash_cs,flash_clk,flash_mosi,flash_wp_n,flash_hold_n,input wire flash_miso
);
    wire clk_sd,clk_mem,clk_mem_sft,clk_video,clk_tmds,sys_lock,video_lock;
    wire rst_all,rst_ref,rst_sd,rst_video;
    player_sys_pll sys_pll_m0(.refclk(clk),.reset(!rst_n),.locked(sys_lock),
        .clk0_out(clk_sd),.clk1_out(clk_mem),.clk2_out(clk_mem_sft));
    player_video_pll video_pll_m0(.refclk(clk),.reset(!rst_n),.locked(video_lock),
        .clk0_out(clk_video),.clk1_out(clk_tmds));
    reset_gen u_reset(.clk(clk),.rst_n(rst_n),.sys_pll_lock(sys_lock),.video_pll_lock(video_lock),.rst_all(rst_all));
    reset_sync r_ref(.clk(clk),.arst(rst_all),.rst(rst_ref));
    reset_sync r_sd(.clk(clk_sd),.arst(rst_all),.rst(rst_sd));
    reset_sync r_video(.clk(clk_video),.arst(rst_all),.rst(rst_video));
    wire rst_storage=rst_all || DIAG_MODE!=0;
    wire next_event,auto_event,prev_event,auto_enabled;
    wire [15:0] settings_sd,settings_video,active_settings;
    wire [21:0] controls_video;
    wire browse_sd,confirm_sd,select_event,player_busy;
    wire [1:0] focus_sd,select_index,visualization_sd,current_sd;
    wire [3:0] cached_slots,catalog_slots,bad_slots;
    wire [17:0] browse_video;
    wire preview_vs,preview_de,preview_active;
    wire [23:0] preview_rgb;
    wire [7:0] wave_bar;
    wire [7:0] wave_peak;
    wire wave_valid;
    wire [15:0] wav_misses;
    wire [9:0] wav_minimum;
    wire [2:0] volume_sd;wire [1:0] transition_sd;
    wire publish_req;
    reg [1:0] publish_style;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) publish_style<=0;else if(!publish_req) publish_style<=transition_sd;
    assign settings_video=controls_video[15:0];
    wire restore_settings,settings_failed,settings_busy;
    wire [15:0] restored_settings;
    player_controls #(.ADVANCED(ENABLE_EXTENSIONS && DIAG_MODE==0),.EXTENDED_MENU(1),.PERSISTENCE(ENABLE_PERSISTENCE && ENABLE_EXTENSIONS)) u_controls(.clk(clk_sd),.rst(rst_sd),.key1(key1),.key2(key2),
        .restore(restore_settings),.restored(restored_settings),
        .available(cached_slots),.current_image(current_sd),.player_busy(player_busy),
        .view_mode(browse_sd),.confirm_pending(confirm_sd),.select_event(select_event),
        .focus_index(focus_sd),.select_index(select_index),.visualization(visualization_sd),
        .next_event(next_event),.auto_event(auto_event),.prev_event(prev_event),.settings(settings_sd),.volume(volume_sd),.transition_kind(transition_sd));
    generate if(ENABLE_PERSISTENCE && ENABLE_EXTENSIONS) begin: persistence
        settings_store u_store(.clk(clk_sd),.rst(rst_sd || DIAG_MODE!=0),.settings(settings_sd),
            .restore(restore_settings),.restored(restored_settings),.busy(settings_busy),.failed(settings_failed),
            .cs(flash_cs),.sck(flash_clk),.mosi(flash_mosi),.miso(flash_miso),.wp_n(flash_wp_n),.hold_n(flash_hold_n));
    end else begin: no_persistence
        assign restore_settings=0;assign restored_settings=0;assign settings_failed=0;assign settings_busy=0;
        assign flash_cs=1;assign flash_clk=0;assign flash_mosi=1;assign flash_wp_n=1;assign flash_hold_n=1;
    end endgenerate
    // SW1 forces contrast 2 and SW2 hides the OSD in the displayed copy only;
    // the menu value (and any persisted value) is left untouched.
    wire key3_prev;
    wire [1:0] switches_sd;
    board_inputs u_board_inputs(.clk(clk_sd),.rst(rst_sd),.key3(key3),.sw(sw),
        .allow_prev(!settings_sd[15] && !browse_sd && !confirm_sd),.prev_event(key3_prev),.switches(switches_sd));
    wire [15:0] display_settings_sd={settings_sd[15:10],switches_sd[0]?2'd2:settings_sd[9:8],
        settings_sd[7] && !switches_sd[1],settings_sd[6:0]};
    status_snapshot #(.WIDTH(22)) u_settings(.src_clk(clk_sd),.src_rst(rst_sd),.value({transition_sd,volume_sd,auto_enabled,display_settings_sd}),
        .dst_clk(clk_video),.dst_rst(rst_video),.snapshot(controls_video));

    status_snapshot #(.WIDTH(18)) u_browse_status(.src_clk(clk_sd),.src_rst(rst_sd),
        .value({visualization_sd,confirm_sd,browse_sd,focus_sd,cached_slots,bad_slots,catalog_slots}),
        .dst_clk(clk_video),.dst_rst(rst_video),.snapshot(browse_video));

    wire sd_init_done,sd_block,init_selected,sector_selected,spi_busy,spi_done;
    wire init_start,sector_start;
    wire [7:0] init_tx,sector_tx,spi_rx;
    wire [3:0] init_error;
    wire [11:0] init_diagnostic;
    wire sector_req,sector_busy,sector_valid,sector_end,sector_error;
    wire [31:0] sector_addr;
    wire [7:0] sector_data;
    wire [11:0] read_diagnostic;
    wire card_req,card_busy,card_valid,card_end,card_error;
    wire [31:0] card_addr;
    wire [7:0] card_data;
    wire fs_mounted,fs_raw,fs_scan_done,fs_found,wav_present,fs_catalog_complete,catalog_continue;
    wire [31:0] fs_handle,wav_size;
    wire [2:0] fs_total;
    wire [7:0] fs_error;
    wire preload_done,wav_req,wav_busy,wav_valid,wav_end,wav_error,wav_ready,wav_underflow;
    wire [31:0] wav_addr;
    wire [7:0] wav_data,wav_fault;
    reg wav_owner;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) wav_owner<=0;
        else wav_owner<=wav_present && preload_done && !fs_raw;
    wire tone_valid,tone_acr;
    wire [23:0] wav_left,wav_right,tone_left,tone_right;
    wire [31:0] logical_address;
    wire recovery_src_rst;
    wire rst_sd_source=rst_sd || DIAG_MODE!=0 || recovery_src_rst;
    // 2 ms power wait: the card is powered with the board and FPGA configuration
    // from U39 already exceeds its settle time; ACMD41 is polled every 1 ms.
    sd_init_seq #(.POWER_WAIT(100_000_000/500),.RETRY_WAIT_CYCLES(100_000_000/1000)) u_init(.clk(clk_sd),.rst(rst_sd_source),.spi_start(init_start),.spi_byte(init_tx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx),.selected(init_selected),
        .init_done(sd_init_done),.init_busy(),.block_addressing(sd_block),.err_code(init_error),.command_diagnostic(init_diagnostic));
    // At least 100 ms of active SCK for a data token at the selected SPI rate.
    sd_rw_sector #(.TOKEN_TIMEOUT(100_000_000/(16*SD_SPI_DIV)/10+1)) u_sector(.clk(clk_sd),.rst(rst_sd_source),.sec_read(card_req),.sec_addr(card_addr),
        .block_addressing(sd_block),.sec_data(card_data),.sec_data_valid(card_valid),.sec_end(card_end),
        .sec_error(card_error),.read_diagnostic(read_diagnostic),.busy(card_busy),.selected(sector_selected),
        .spi_start(sector_start),.spi_byte(sector_tx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx));
    // The MISO multicycle hold check is outside TD hold repair. A fixed pad
    // delay (0.52 ns + 4 taps x 0.12 ns) removes its dependence on RX placement.
    wire sd_miso_delayed;
    EG_LOGIC_IDELAY #(.INDEL(4)) u_miso_delay(.i(sd_miso),.o(sd_miso_delayed));
    // Identification SCK 100 MHz/(2*128) = 390.6 kHz (<=400 kHz).
    sd_spi #(.DIV(SD_SPI_DIV),.LOW_DIV(128)) u_spi(.clk(clk_sd),.rst(rst_sd_source),.selected(sd_init_done?sector_selected:init_selected),.low_speed(!sd_init_done),
        .spi_start(sd_init_done?sector_start:init_start),.spi_byte(sd_init_done?sector_tx:init_tx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(spi_rx),
        .sck(sd_dclk),.cs(sd_ncs),.mosi(sd_mosi),.miso(sd_miso_delayed));

    wire bmp_ready,scan_start,scan_done,found,load_start,load_abort;
    wire [31:0] found_sector,load_sector;
    wire [2:0] found_total;
    wire bmp_req,bmp_ack,px_valid,px_ready,load_done,load_error,bmp_progress;
    wire [23:0] px_data;
    wire [3:0] bmp_state;
    wire [15:0] source_width,source_height;
    wire source_top_down;
    wire bmp_scan_done,bmp_found;
    wire [31:0] bmp_found_sector;
    wire [2:0] bmp_found_total;
    assign scan_done=fs_raw?bmp_scan_done:fs_scan_done;
    assign found=fs_raw?bmp_found:fs_found;
    assign found_sector=fs_raw?bmp_found_sector:fs_handle;
    assign found_total=fs_raw?bmp_found_total:fs_total;
    generate if(ENABLE_FILESYSTEM && ENABLE_EXTENSIONS) begin: filesystem
        wire service_busy,service_valid,service_end,service_error;
        wire [7:0] service_data;
        assign sector_busy=service_busy || wav_owner;
        assign sector_valid=service_valid && !wav_owner;assign sector_end=service_end && !wav_owner;
        assign sector_error=service_error && !wav_owner;assign sector_data=service_data;
        assign wav_busy=service_busy || !wav_owner;
        assign wav_valid=service_valid && wav_owner;assign wav_end=service_end && wav_owner;
        assign wav_error=service_error && wav_owner;assign wav_data=service_data;
        assign logical_address=wav_owner?wav_addr:sector_addr;
        fat32_media #(.EARLY_CATALOG(1)) u_fs(.catalog_resume(catalog_continue),.catalog_complete(fs_catalog_complete),.clk(clk_sd),.rst(rst_sd_source),.init_done(sd_init_done),
            .mounted(fs_mounted),.raw_mode(fs_raw),.fs_error(fs_error),
            .catalog_start(scan_start && !fs_raw),.catalog_done(fs_scan_done),.found_valid(fs_found),
            .found_handle(fs_handle),.found_total(fs_total),.wav_present(wav_present),.wav_size(wav_size),
            .req(wav_owner?wav_req:sector_req),.address(logical_address),.busy(service_busy),.data(service_data),
            .valid(service_valid),.ending(service_end),.error(service_error),
            .sector_req(card_req),.sector_addr(card_addr),.sector_busy(card_busy),.sector_valid(card_valid),
            .sector_end(card_end),.sector_error(card_error),.sector_data(card_data));
    end else begin: raw_storage
        assign card_req=sector_req;assign card_addr=sector_addr;assign sector_busy=card_busy;
        assign sector_data=card_data;assign sector_valid=card_valid;assign sector_end=card_end;assign sector_error=card_error;
        assign fs_catalog_complete=1;assign fs_mounted=1'b1;assign fs_raw=1'b1;assign fs_error=0;
        assign fs_scan_done=0;assign fs_found=0;assign fs_handle=0;assign fs_total=0;assign wav_present=0;assign wav_size=0;
        assign wav_busy=1;assign wav_valid=0;assign wav_end=0;assign wav_error=0;assign wav_data=0;assign logical_address=sector_addr;
    end endgenerate
    bmp_decoder #(.FLEXIBLE_SIZE(ENABLE_EXTENSIONS)) u_bmp(.clk(clk_sd),.rst(rst_sd || DIAG_MODE!=0),.sd_init_done(sd_init_done && fs_mounted),.ready(bmp_ready),
        .sd_sec_read(sector_req),.sd_sec_addr(sector_addr),.sd_sec_data(sector_data),
        .sd_sec_data_valid(sector_valid),.sd_sec_end(sector_end),.sd_sec_busy(sector_busy),.sd_sec_error(sector_error),
        .bmp_width(ENABLE_EXTENSIONS?16'd1280:16'd640),.bmp_height(ENABLE_EXTENSIONS?16'd960:16'd480),.scan_start(scan_start && fs_raw),.scan_done(bmp_scan_done),
        .scan_found_valid(bmp_found),.scan_found_sector(bmp_found_sector),.scan_found_total(bmp_found_total),
        .load_start(load_start),.load_abort(load_abort),.load_sector(load_sector),
        .write_req(bmp_req),.write_req_ack(bmp_ack),.px_wr_en(px_valid),.px_data(px_data),.px_ready(px_ready),
        .load_done(load_done),.load_error(load_error),.progress(bmp_progress),.state_code(bmp_state),
        .source_width(source_width),.source_height(source_height),.source_top_down(source_top_down));
    wire scaled_valid,scaled_ready,scaled_done,scaled_error,scaler_idle;
    wire [23:0] scaled_data;
    reg bmp_req_d;
    always @(posedge clk_sd or posedge rst_sd) if(rst_sd) bmp_req_d<=0;else bmp_req_d<=bmp_req;
    generate if(ENABLE_EXTENSIONS) begin: scale_path
        bilinear_scaler u_scale(.clk(clk_sd),.rst(rst_sd || DIAG_MODE!=0),.start(bmp_req && !bmp_req_d),.abort_load(load_abort),
            .source_width(source_width),.source_height(source_height),.in_valid(px_valid),.in_data(px_data),.in_ready(px_ready),
            .in_done(load_done),.in_error(load_error),.out_valid(scaled_valid),.out_data(scaled_data),.out_ready(scaled_ready),
            .done(scaled_done),.error(scaled_error),.idle(scaler_idle));
    end else begin: no_scale
        assign scaled_valid=px_valid;assign scaled_data=px_data;assign px_ready=scaled_ready;
        assign scaled_done=load_done;assign scaled_error=load_error;assign scaler_idle=1'b1;
    end endgenerate

    wire write_req,write_ack,write_en,write_ready,write_finish;
    wire [31:0] write_data;
    wire [1:0] write_buf,target_image,memory_image,display_image;
    wire media_valid;
    wire write_abort,write_abort_ack,publish_ack,player_error,player_display_valid,load_success,cancel_abort;
    // A key-cancelled background preload is not a media fault.
    wire media_load_error=(scaled_error || load_error) && !cancel_abort;
    wire publish_fade,memory_publish_req,memory_publish_ack;
    wire recovery_key; reg recovery_evt,recovery_evt_d;
    reg finish_toggle;
    wire rst_mem;
    reset_sync r_mem(.clk(clk_mem),.arst(rst_all),.rst(rst_mem));
    always @(posedge clk_mem or posedge rst_mem)
        if(rst_mem) finish_toggle<=0;else if(write_finish) finish_toggle<=~finish_toggle;
    sd_player #(.DIRECT_SELECT(ENABLE_EXTENSIONS),.KEY_EVENTS(ENABLE_EXTENSIONS),.RUNTIME_CONTROL(ENABLE_EXTENSIONS),.PRELOAD(ENABLE_EXTENSIONS),.RETRY_INPUT(1),.SKIP_BAD(ENABLE_EXTENSIONS),.STREAM_CATALOG(ENABLE_FILESYSTEM && ENABLE_EXTENSIONS)) u_player(.clk(clk_sd),.rst(rst_sd || DIAG_MODE!=0),
        .retry_load(recovery_evt),.key_next(ENABLE_EXTENSIONS?next_event:key1),.key_auto(ENABLE_EXTENSIONS?auto_event:key2),.sd_init_done(sd_init_done),
        .display_valid(player_display_valid),.state_code(),.write_finish_t(finish_toggle),
        .key_prev(ENABLE_EXTENSIONS?prev_event || key3_prev:1'b0),.period_select(settings_sd[5:4]),
        .select_request(select_event),.select_index(select_index),.browse_active(browse_sd),
        .cached_slots(cached_slots),.catalog_slots(catalog_slots),.control_busy(player_busy),.cancel_abort(cancel_abort),
        .current_image(current_sd),.target_image(target_image),.auto_enabled(auto_enabled),
        .write_req(write_req),.write_req_ack(write_ack),.write_en(write_en),.write_data(write_data),.write_ready(write_ready),
        .write_buf_idx(write_buf),.disp_buf_idx(),.bmp_write_req(bmp_req),.bmp_write_req_ack(bmp_ack),
        .scan_start(scan_start),.load_start(load_start),.load_sector(load_sector),.bmp_ready(bmp_ready && scaler_idle),
        .scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(found_total),
        .load_abort(load_abort),.bmp_px_wr_en(scaled_valid),.bmp_px_data(scaled_data),.bmp_px_ready(scaled_ready),
        .bmp_load_done(scaled_done || (load_done && load_error)),.bmp_load_error(scaled_error || load_error),
        .bmp_progress(bmp_progress || (scaled_valid && scaled_ready)),
        .write_abort(write_abort),.write_abort_ack(write_abort_ack),
        .publish_req(publish_req),.publish_ack(publish_ack),.publish_fade(publish_fade),.error(player_error),.load_success(load_success),.preload_done(preload_done),
        .catalog_complete(fs_raw?1'b1:fs_catalog_complete),.catalog_continue(catalog_continue),.bad_slots(bad_slots));
    // Init failure: reset only init/sector/SPI; player and decoder still wait
    // for init_done. Load failure: let abort settle, then inject a key event.
    // Keep the retry budget and first-fault diagnostics outside source reset.
    reg recovery_progress;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) recovery_progress<=0;
        else recovery_progress<=card_valid || bmp_progress || (scaled_valid && scaled_ready);
    // Sticky initialization faults tolerate one SD clock of detection latency.
    // Register the reduction before the recovery state/timer fanout.
    reg recovery_init_error;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) recovery_init_error<=0;
        else recovery_init_error<=init_error!=0 || (!fs_mounted && fs_error!=0);
    media_recovery #(.CLK_FREQ_HZ(100_000_000)) u_recovery(.clk(clk_sd),.rst(rst_sd || DIAG_MODE!=0),
        .media_error(player_error),.init_error(recovery_init_error),.display_valid(player_display_valid),
        .load_success(load_success),.progress(recovery_progress),
        .key_retry(recovery_key),.src_rst(recovery_src_rst),.attempts(),.failed());
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) begin recovery_evt_d<=0;recovery_evt<=0;end
        else begin recovery_evt_d<=recovery_key;recovery_evt<=recovery_key && !recovery_evt_d;end

    wire sdr_init,sdr_refresh,sdr_busy,wr_busy,rd_busy;
    wire [20:0] app_wr_addr,app_rd_addr;
    wire [31:0] app_wr_data,sdr_data,read_data;
    wire [3:0] app_wr_dm;
    wire app_wr_en,app_rd_en,sdr_valid,read_req,read_ack,read_en,read_valid,display_mem;
    wire memory_error,underflow;
    sdram_write_ctrl #(.DYNAMIC_ORIENTATION(ENABLE_EXTENSIONS)) u_wr(.clk_sd(clk_sd),.mem_clk(clk_mem),.rst(rst_storage),
        .Sdr_init_done(sdr_init),.Sdr_init_ref_vld(sdr_refresh),.Sdr_busy(sdr_busy),.rd_busy(rd_busy),.wr_busy(wr_busy),
        .write_req(write_req),.write_req_ack(write_ack),.write_abort(write_abort),.write_abort_ack(write_abort_ack),
        .write_addr0(21'd0),.write_addr1(21'd307200),.write_addr2(21'd614400),.write_addr3(21'd921600),
        .write_addr_idx(write_buf),.write_len(21'd307200),.write_en(write_en),.write_data(write_data),
        .write_ready(write_ready),.write_finish(write_finish),.App_wr_dm(app_wr_dm),
        .App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),.App_wr_din(app_wr_data),.source_top_down(source_top_down));
    sdram_read_ctrl #(.WIPE_FRAMES(ENABLE_EXTENSIONS?20:0),.MANUAL_FADE(ENABLE_EXTENSIONS),.ENHANCED_WIPE(ENABLE_EXTENSIONS)) u_rd(.mem_clk(clk_mem),.clk_video(clk_video),.rst(rst_storage),
        .Sdr_init_done(sdr_init),.Sdr_init_ref_vld(sdr_refresh),.Sdr_busy(sdr_busy),.wr_busy(wr_busy),.rd_busy(rd_busy),
        .read_req(read_req),.read_req_ack(read_ack),.read_finish(),
        .publish_req(memory_publish_req),.publish_buf(write_buf),.publish_ack(memory_publish_ack),.display_valid(display_mem),.publish_fade(publish_fade),
        .publish_image(target_image),.display_image(memory_image),.wipe_kind(publish_style),
        .read_addr0(21'd0),.read_addr1(21'd307200),.read_addr2(21'd614400),.read_addr3(21'd921600),.read_len(21'd307200),
        .Sdr_rd_en(sdr_valid),.Sdr_rd_dout(sdr_data),.App_rd_en(app_rd_en),.App_rd_addr(app_rd_addr),
        .read_en(read_en),.read_data(read_data),.read_valid(read_valid),.memory_error(memory_error),.underflow(underflow));
    sdram u_sdram(.Clk(clk_mem),.Clk_sft(clk_mem_sft),.Rst(rst_mem || DIAG_MODE!=0),.Sdr_init_done(sdr_init),
        .Sdr_init_ref_vld(sdr_refresh),.Sdr_busy(sdr_busy),.App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),
        .App_wr_dm(app_wr_dm),.App_wr_din(app_wr_data),.App_rd_en(app_rd_en),.App_rd_addr(app_rd_addr),
        .Sdr_rd_en(sdr_valid),.Sdr_rd_dout(sdr_data));

    wire hs,vs,de,aligned_hs,aligned_vs,aligned_de;
    wire [23:0] rgb,axis_data;
    wire axis_user,axis_valid,axis_last,axis_ready,axis_overflow;
    wire diagnostic_ack,diagnostic_valid;
    wire [23:0] diagnostic_data;
    wire consumer_read;
    assign read_en=DIAG_MODE==0?consumer_read:1'b0;
    diagnostic_pattern u_pattern(.clk(clk_video),.rst(rst_video),.read_req(read_req),
        .read_en(DIAG_MODE==1 && consumer_read),.read_ack(diagnostic_ack),.read_valid(diagnostic_valid),.read_data(diagnostic_data));
    (* async_reg="true" *) reg [2:0] display_sync;
    always @(posedge clk_video or posedge rst_video)
        if(rst_video) display_sync<=0;else display_sync<={display_sync[1:0],display_mem};
    video_timing_gen u_timing(.video_clk(clk_video),.rst(rst_video),.read_req(read_req),.read_req_ack(DIAG_MODE!=0?diagnostic_ack:read_ack),
        .hs(hs),.vs(vs),.de(de));
    video_pixel_align u_align(.video_clk(clk_video),.rst(rst_video),
        .read_en(consumer_read),.read_data(DIAG_MODE==1?diagnostic_data:read_data[31:8]),
        .read_valid(DIAG_MODE==1?diagnostic_valid:read_valid),.display_enable(DIAG_MODE==1 || display_sync[2]),
        .hs(hs),.vs(vs),.de(de),.hs_r(aligned_hs),.vs_r(aligned_vs),.de_r(aligned_de),.vout_data(rgb));
    wire overlay_vs,overlay_de,frame_start,spectrum_valid,spectrum_overflow;
    wire [23:0] overlay_rgb;
    wire [7:0] spectrum_bar;
    wire [4:0] vis_bin;
    wire [3:0] status_video;
    frame_media_status u_media_status(.clk(clk_video),.rst(rst_video),.read_ack(read_ack),
        .i_vs(aligned_vs),.i_de(aligned_de),.display_enable(display_sync[2]),.memory_image(memory_image),
        .image_index(display_image),.image_valid(media_valid));
    wire [108:0] diagnostics_video;
    wire [4:0] fade_gain;
    frame_fade #(.ENABLED(ENABLE_EXTENSIONS && DIAG_MODE==0)) u_fade(
        .ctrl_clk(clk_sd),.ctrl_rst(rst_sd),.pix_clk(clk_video),.pix_rst(rst_video),
        .publish_req(publish_req),.publish_fade(publish_fade),.memory_ack(memory_publish_ack),
        .memory_req(memory_publish_req),.publish_ack(publish_ack),
        .i_vs(aligned_vs),.fade_gain(fade_gain));
    generate if(ENABLE_EXTENSIONS && DIAG_MODE==0) begin: preview_path
        thumbnail_preview u_preview(.sd_clk(clk_sd),.sd_rst(rst_sd),
            .load_start(bmp_req && !bmp_req_d),.abort_load(load_abort),.write_pixel(write_en),
            .source_top_down(source_top_down),.write_slot(write_buf),.write_rgb(write_data[31:8]),
            .clk(clk_video),.rst(rst_video),.i_vs(aligned_vs),.i_de(aligned_de),.i_rgb(rgb),
            .view_mode(browse_video[14]),.confirm_pending(browse_video[15]),.focus(browse_video[13:12]),
            .complete(browse_video[11:8]),.bad(browse_video[7:4]),.catalog(browse_video[3:0]),
            .fade_gain(fade_gain),.o_vs(preview_vs),.o_de(preview_de),.o_rgb(preview_rgb),.active_view(preview_active));
    end else begin: no_preview
        assign preview_vs=aligned_vs;assign preview_de=aligned_de;assign preview_rgb=rgb;assign preview_active=0;
    end endgenerate
    wire [32:0] media_info_sd,media_info_video;
    // Player build: Chinese scene OSD. Base and diagnostic profiles keep video_overlay.
    wire [3:0] catalog_video=browse_video[3:0];
    wire [2:0] image_total=catalog_video[0]+catalog_video[1]+catalog_video[2]+catalog_video[3];
    generate if(ENABLE_EXTENSIONS && DIAG_MODE==0) begin: scene_osd
    scene_overlay u_overlay(.clk(clk_video),.rst(rst_video),.i_vs(preview_vs),.i_de(preview_de),.i_rgb(preview_rgb),
        .image_total(image_total),
        .visualization(browse_video[17:16]),.overview(preview_active),.focus(browse_video[13:12]),
        .wave_bar(wave_bar),.wave_peak(wave_peak),.wave_valid(wave_valid),
        .wav_misses(wav_misses),.wav_minimum(wav_minimum),.media_info(media_info_video),
        .fade_gain(fade_gain),.volume(controls_video[19:17]),.transition_kind(controls_video[21:20]),
        .diagnostics(diagnostics_video),
        .image_valid(display_sync[2] || preview_active),
        .settings(settings_video),.error_code(status_video),
        .image_index(display_image),.media_valid(media_valid && display_sync[2]),.auto_enabled(controls_video[16]),.spectrum_bar(spectrum_bar),.spectrum_valid(spectrum_valid),
        .o_vs(overlay_vs),.o_de(overlay_de),.o_rgb(overlay_rgb),.frame_start(frame_start),.active_settings(active_settings),.vis_bin(vis_bin));
    end else begin: classic_osd
    video_overlay #(.ADVANCED(ENABLE_EXTENSIONS && DIAG_MODE==0),.ENHANCED(ENABLE_EXTENSIONS),.DIAGNOSTICS(ENABLE_EXTENSIONS),.FADE(ENABLE_EXTENSIONS && DIAG_MODE==0)) u_overlay(.clk(clk_video),.rst(rst_video),.i_vs(preview_vs),.i_de(preview_de),.i_rgb(preview_rgb),
        .visualization(browse_video[17:16]),.overview(preview_active),.focus(browse_video[13:12]),
        .wave_bar(wave_bar),.wave_peak(wave_peak),.wave_valid(wave_valid),
        .wav_misses(wav_misses),.wav_minimum(wav_minimum),.media_info(media_info_video),
        .fade_gain(fade_gain),.volume(controls_video[19:17]),.transition_kind(controls_video[21:20]),
        .diagnostics(diagnostics_video),
        .image_valid(display_sync[2] || preview_active || DIAG_MODE==1),
        .settings(settings_video),.error_code(status_video),
        .image_index(display_image),.media_valid(media_valid && display_sync[2]),.auto_enabled(controls_video[16]),.spectrum_bar(spectrum_bar),.spectrum_valid(spectrum_valid),
        .o_vs(overlay_vs),.o_de(overlay_de),.o_rgb(overlay_rgb),.frame_start(frame_start),.active_settings(active_settings),.vis_bin(vis_bin));
    end endgenerate
    rgb_to_axis u_axis(.clk(clk_video),.rst(rst_video),.i_vs(ENABLE_EXTENSIONS?overlay_vs:aligned_vs),
        .i_de(DIAG_MODE==2?1'b0:ENABLE_EXTENSIONS?overlay_de:aligned_de),.i_rgb(ENABLE_EXTENSIONS?overlay_rgb:rgb),
        .i_ready(axis_ready),.o_user(axis_user),.o_valid(axis_valid),.o_last(axis_last),.o_data(axis_data),.overflow(axis_overflow));

    wire audio_valid,acr_valid,mixed_valid,mixed_acr;
    wire [23:0] mixed_left,mixed_right;
    reg sample_aligned,acr_aligned;
    wire edid_trig;
    wire [23:0] audio_left,audio_right;
    wire [19:0] acr_cts,acr_n;
    wire [9:0] ch0,ch1,ch2,chclk;
    reg [23:0] tone_left_q,tone_right_q;
    (* async_reg="true" *) reg [2:0] wav_sync,wav_present_sync;
    always @(posedge clk_video or posedge rst_video) begin
        if(rst_video) begin sample_aligned<=0;acr_aligned<=0;tone_left_q<=0;tone_right_q<=0;wav_sync<=0;wav_present_sync<=0;end
        else begin
            sample_aligned<=tone_valid;acr_aligned<=tone_acr;tone_left_q<=tone_left;tone_right_q<=tone_right;
            wav_sync<={wav_sync[1:0],wav_owner};wav_present_sync<={wav_present_sync[1:0],wav_present};
        end
    end
    // A card with music stays silent while images preload instead of playing the image tone.
    wire wav_waiting=wav_present_sync[2] && !wav_sync[2];
    audio_source_mux u_audio_mux(.clk(clk_video),.rst(rst_video),.sample_valid(sample_aligned),.acr_in(acr_aligned),
        .select_wav(wav_sync[2] && active_settings[3]),.tone_left(tone_left_q),.tone_right(tone_right_q),
        .wav_left(wav_left),.wav_right(wav_right),.valid(mixed_valid),.acr_out(mixed_acr),.left(mixed_left),.right(mixed_right));
    audio_gain u_volume(.clk(clk_video),.rst(rst_video),.valid_in(mixed_valid),.acr_in(mixed_acr),
        .volume(ENABLE_EXTENSIONS?controls_video[19:17]:3'd4),.left_in(mixed_left),.right_in(mixed_right),
        .valid_out(audio_valid),.acr_out(acr_valid),.left_out(audio_left),.right_out(audio_right));
    generate if(ENABLE_FILESYSTEM && ENABLE_EXTENSIONS) begin: wav_path
        wav_player u_wav(.clk(clk_sd),.video_clk(clk_video),.rst(rst_all || DIAG_MODE!=0),
            .enable(wav_owner),.file_size(wav_size),.req(wav_req),.address(wav_addr),
            .busy(wav_busy),.valid(wav_valid),.ending(wav_end),.error(wav_error),.data(wav_data),
            .sample_tick(tone_valid),.play(1'b1),.left(wav_left),.right(wav_right),
            .ready(wav_ready),.fault(wav_fault),.underflow(wav_underflow),.missed_samples(wav_misses),.minimum_level(wav_minimum));
    end else begin: no_wav
        assign wav_req=0;assign wav_addr=0;assign wav_left=0;assign wav_right=0;
        assign wav_ready=0;assign wav_fault=0;assign wav_underflow=0;assign wav_misses=0;assign wav_minimum=0;
    end endgenerate
    audio_tone_i2s #(.ENABLE_MEDIA(ENABLE_EXTENSIONS)) u_audio(.clk(clk_video),.rst(rst_video),.audio_valid(tone_valid),
        .audio_left(tone_left),.audio_right(tone_right),.acr_valid(tone_acr),.acr_cts(acr_cts),.acr_n(acr_n),
        .media_mode(active_settings[3]),.media_valid(media_valid && display_sync[2] && !wav_waiting),.media_index(display_image));
    generate if(ENABLE_EXTENSIONS) begin: spectrum_path
        audio_waveform u_wave(.clk(clk_video),.rst(rst_video),.sample_valid(audio_valid),.sample(audio_left),
            .frame_start(frame_start),.rd_bin(vis_bin),.rd_sample(wave_bar),.peak(wave_peak),.valid(wave_valid));
        audio_spectrum u_spectrum(.clk(clk_video),.rst(rst_video),.sample_valid(audio_valid),.sample(audio_left),
            .frame_start(frame_start),.rd_bin(vis_bin),.rd_level(spectrum_bar),.valid(spectrum_valid),.overflow(spectrum_overflow),.blocks(),.dropped_samples());
    end else begin: no_spectrum
        assign spectrum_bar=0;assign spectrum_valid=0;assign spectrum_overflow=0;assign wave_bar=0;assign wave_peak=0;assign wave_valid=0;
    end endgenerate
    startup_pulse u_startup(.clk(clk_video),.rst(rst_video),.o_pulse(edid_trig));
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),.HTOTAL(800),.HSA(96),.HFP(16),.HBP(48),.HACTIVE(640),
        .VTOTAL(525),.VSA(2),.VFP(10),.VBP(33),.VACTIVE(480),
        .VIDEO_VIC(1),.VIDEO_TPG(DIAG_MODE==2?"Enable":"Disable"),.VIDEO_FORMAT("RGB"),.AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(250)
    ) u_hdmi_core(.I_pixel_clk(clk_video),.I_rst(rst_video),.I_edid_read_trig(edid_trig),
        .O_edid_read_valid(),.O_edid_read_data(),.I_axis_s_user(axis_user),.I_axis_s_valid(axis_valid),
        .I_axis_s_last(axis_last),.I_axis_s_data(axis_data),.O_axis_s_ready(axis_ready),
        .I_audio_valid(audio_valid),.I_audio_left_data(audio_left),.I_audio_right_data(audio_right),
        .I_acr_valid(acr_valid),.I_acr_cts(acr_cts),.I_acr_n(acr_n),.O_video_locked(),
        .O_ddc_scl(HDMI_DDC_SCL),.IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(ch0),.O_ch1_tmds_data(ch1),.O_ch2_tmds_data(ch2),.O_clk_tmds_data(chclk));
    hdmi_phy_wrapper u_phy(.I_pixel_clk(clk_video),.I_serial_clk(clk_tmds),.I_rst(rst_video),
        .I_tmds_channel_0(ch0),.I_tmds_channel_1(ch1),.I_tmds_channel_2(ch2),.I_tmds_channel_clk(chclk),
        .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));

    (* async_reg="true" *) reg [2:0] memory_error_sync,video_error_sync;
    always @(posedge clk_sd or posedge rst_sd) begin
        if(rst_sd) begin memory_error_sync<=0;video_error_sync<=0;end
        else begin
            memory_error_sync<={memory_error_sync[1:0],memory_error};
            video_error_sync<={video_error_sync[1:0],underflow || axis_overflow};
        end
    end
    (* async_reg="true" *) reg [2:0] underflow_sync,axis_sync,spectrum_sync,wav_underflow_sync;
    always @(posedge clk_sd or posedge rst_sd) begin
        if(rst_sd) begin underflow_sync<=0;axis_sync<=0;spectrum_sync<=0;wav_underflow_sync<=0;end
        else begin underflow_sync<={underflow_sync[1:0],underflow};axis_sync<={axis_sync[1:0],axis_overflow};spectrum_sync<={spectrum_sync[1:0],spectrum_overflow};wav_underflow_sync<={wav_underflow_sync[1:0],wav_underflow};end
    end
    wire [3:0] status_sd=init_error!=0?4'hf:memory_error_sync[2]?4'hd:
        underflow_sync[2]?4'hc:axis_sync[2]?4'hb:spectrum_sync[2]?4'ha:
        (player_error || media_load_error || fs_error!=0 || wav_fault!=0 || wav_underflow_sync[2] || settings_failed)?4'he:DIAG_MODE!=0?4'd8:bmp_state;
    (* async_reg="true" *) reg [2:0] sdr_init_sync;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) sdr_init_sync<=0;else sdr_init_sync<={sdr_init_sync[1:0],sdr_init};
    wire [108:0] diagnostics_sd;
    wire [11:0] media_diagnostic=init_error!=0?init_diagnostic:
        fs_error!=0?{4'h7,fs_error}:wav_fault!=0?{4'h8,wav_fault}:
        wav_underflow_sync[2]?12'h8f0:settings_failed?12'h900:read_diagnostic;
    board_diagnostics u_board_diag(.clk(clk_sd),.rst(rst_sd),.status_code(status_sd),
        .init_error(init_error),.bmp_state(bmp_state),.found_total(found_total),
        .read_diagnostic(media_diagnostic),
        .flags({sd_init_done,sd_block,sdr_init_sync[2],1'b0,player_error,load_error,scaled_error,
                scan_done,sector_busy,bmp_req,bmp_ack,scaled_valid,scaled_ready,scaled_done,write_abort,publish_req}),
        .sector_req(sector_req),.sector_valid(sector_valid),.sector_error(sector_error),
        .load_start(load_start),.pixel_accept(scaled_valid && scaled_ready),
        .sector_addr(sector_addr),.sector_data(sector_data),.report(diagnostics_sd));
    osd_sd_meter u_media_meter(.clk(clk_sd),.rst(rst_sd),.init_done(sd_init_done),.load_done(scaled_done && !scaled_error),
        .load_slot(target_image),.shown_slot(current_sd),.width(source_width[10:0]),.height(source_height[9:0]),.info(media_info_sd));
    status_snapshot #(.WIDTH(33)) u_media_info(.src_clk(clk_sd),.src_rst(rst_sd),.value(media_info_sd),
        .dst_clk(clk_video),.dst_rst(rst_video),.snapshot(media_info_video));
    status_snapshot #(.WIDTH(109)) u_diagnostics(.src_clk(clk_sd),.src_rst(rst_sd),.value(diagnostics_sd),
        .dst_clk(clk_video),.dst_rst(rst_video),.snapshot(diagnostics_video));
    status_snapshot u_video_status(.src_clk(clk_sd),.src_rst(rst_sd),.value(status_sd),
        .dst_clk(clk_video),.dst_rst(rst_video),.snapshot(status_video));
    wire [3:0] image_ref;
    status_snapshot u_image_status(.src_clk(clk_video),.src_rst(rst_video),
        .value((media_valid && display_sync[2])?({2'b0,display_image}+4'd1):4'd0),
        .dst_clk(clk),.dst_rst(rst_ref),.snapshot(image_ref));
    wire [3:0] status_ref;
    wire [3:0] panel_code=(DIAG_MODE==0 && status_ref<4'ha && image_ref!=0)?image_ref:status_ref;
    status_snapshot u_status(.src_clk(clk_sd),.src_rst(rst_sd),.value(status_sd),
        .dst_clk(clk),.dst_rst(rst_ref),.snapshot(status_ref));
    wire [8:0] panel_settings;
    status_snapshot #(.WIDTH(9)) u_panel_settings(.src_clk(clk_sd),.src_rst(rst_sd),
        .value({settings_sd[15],settings_sd[14:12],volume_sd,settings_sd[5:4]}),
        .dst_clk(clk),.dst_rst(rst_ref),.snapshot(panel_settings));
    // Indicator sources cross into the 50 MHz reference domain as registered levels.
    // LED1 = image loading: the player leaves IDLE for first load, preload and
    // switches, but stays IDLE while WAV streams from the card.
    reg [1:0] indicator_sd;
    reg audio_level;
    always @(posedge clk_sd or posedge rst_sd)
        if(rst_sd) indicator_sd<=0;else indicator_sd<={player_busy,auto_enabled};
    always @(posedge clk_video or posedge rst_video)
        if(rst_video) audio_level<=0;else audio_level<=|wave_peak[7:1];
    (* async_reg="true" *) reg [2:0] auto_ref_sync,card_ref_sync,audio_ref_sync;
    always @(posedge clk or posedge rst_ref) begin
        if(rst_ref) begin auto_ref_sync<=0;card_ref_sync<=0;audio_ref_sync<=0;end
        else begin
            auto_ref_sync<={auto_ref_sync[1:0],indicator_sd[0]};card_ref_sync<={card_ref_sync[1:0],indicator_sd[1]};
            audio_ref_sync<={audio_ref_sync[1:0],audio_level};
        end
    end
    board_indicators u_indicators(.clk(clk),.rst(rst_ref),.auto_enabled(auto_ref_sync[2]),.card_active(card_ref_sync[2]),
        .audio_active(audio_ref_sync[2]),.fault(status_ref>=4'ha),.led(led),.buzzer_n(buzzer));
    // Any key held keeps the panel awake; raw levels suffice since a bounce only wakes it.
    (* async_reg="true" *) reg [1:0] key_ref_sync;
    always @(posedge clk or posedge rst_ref)
        if(rst_ref) key_ref_sync<=2'b11;else key_ref_sync<={key_ref_sync[0],key1 && key2 && key3};
    generate if(ENABLE_EXTENSIONS) begin: full_panel
        player_panel u_seg(.clk(clk),.rst(rst_ref),.status(status_ref),.image(image_ref),
            .menu(panel_settings[8]),.activity(!key_ref_sync[1]),.selection(panel_settings[7:5]),.volume(panel_settings[4:2]),.period(panel_settings[1:0]),
            .seg_sel(seg_sel),.seg_data(seg_data));
    end else begin: simple_panel
        seg_disp #(.CLK_FREQ_HZ(50_000_000)) u_seg(.clk(clk),.rst_n(!rst_ref),
            .state_code(panel_code),.seg_sel(seg_sel),.seg_data(seg_data));
    end endgenerate
endmodule
