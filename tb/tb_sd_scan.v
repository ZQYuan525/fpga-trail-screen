`timescale 1ns/1ps
// Real SPI/init/sector/BMP/player chain; card delays each token by >2 ms.
module tb_sd_scan #(parameter TOKEN_BUDGET=100_000_000/(16*3)/10+1);
    reg clk=0,rst=0;always #5 clk=~clk;
    wire initialized,block_addr,isel,ssel,istart,sstart,spi_busy,spi_done;
    wire [7:0] itx,stx,rx,data;
    wire [3:0] init_error,bmp_state;
    wire [11:0] read_diagnostic;
    wire cs,sck,mosi,miso,sector_busy,valid,ending,sector_error,sector_req;
    wire [31:0] address,found_sector,load_sector;
    wire scan_start,scan_done,found,load_start,load_abort,bmp_ready,breq,back;
    wire px_valid,px_ready,load_done,load_error,progress,write_req,player_error;
    wire [23:0] pixel;
    wire [2:0] total;
    integer commands,preclocks,found_count=0;
    sd_init_seq #(.POWER_WAIT(10)) init(.clk(clk),.rst(rst),.spi_start(istart),.spi_byte(itx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx),.selected(isel),
        .init_done(initialized),.init_busy(),.block_addressing(block_addr),.err_code(init_error));
    sd_rw_sector #(.TOKEN_TIMEOUT(TOKEN_BUDGET)) sector(.clk(clk),.rst(rst),.sec_read(sector_req),
        .sec_addr(address),.block_addressing(block_addr),.sec_data(data),.sec_data_valid(valid),
        .sec_end(ending),.sec_error(sector_error),.read_diagnostic(read_diagnostic),.busy(sector_busy),.selected(ssel),
        .spi_start(sstart),.spi_byte(stx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx));
    sd_spi #(.DIV(3),.LOW_DIV(4)) spi(.clk(clk),.rst(rst),.selected(initialized?ssel:isel),
        .low_speed(!initialized),.spi_start(initialized?sstart:istart),.spi_byte(initialized?stx:itx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx),.sck(sck),.cs(cs),.mosi(mosi),.miso(miso));
    sd_card_model #(.BMP_HEADERS(1)) card(.rst(rst),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),
        .card_type(2'd2),.fault(4'd10),.command17_count(commands),.preclocks(preclocks));
    bmp_decoder #(.FLEXIBLE_SIZE(1),.SCAN_MAX(5403)) bmp(.clk(clk),.rst(rst),.sd_init_done(initialized),
        .ready(bmp_ready),.sd_sec_read(sector_req),.sd_sec_addr(address),.sd_sec_data(data),
        .sd_sec_data_valid(valid),.sd_sec_end(ending),.sd_sec_busy(sector_busy),.sd_sec_error(sector_error),
        .bmp_width(16'd1280),.bmp_height(16'd960),.scan_start(scan_start),.scan_done(scan_done),
        .scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(total),
        .load_start(load_start),.load_abort(load_abort),.load_sector(load_sector),.write_req(breq),.write_req_ack(back),
        .px_wr_en(px_valid),.px_data(pixel),.px_ready(px_ready),.load_done(load_done),.load_error(load_error),
        .progress(progress),.state_code(bmp_state),.source_width(),.source_height(),.source_top_down());
    sd_player #(.KEY_EVENTS(1)) player(.clk(clk),.rst(rst),.key_next(1'b0),.key_auto(1'b0),
        .key_prev(1'b0),.period_select(2'd0),.sd_init_done(initialized),.current_image(),.target_image(),
        .auto_enabled(),.display_valid(),.state_code(),.write_finish_t(1'b0),.write_req(write_req),.write_req_ack(1'b0),
        .write_en(),.write_data(),.write_ready(1'b0),.write_buf_idx(),.disp_buf_idx(),
        .bmp_write_req(breq),.bmp_write_req_ack(back),.scan_start(scan_start),.load_start(load_start),
        .load_abort(load_abort),.load_sector(load_sector),.bmp_ready(bmp_ready),.scan_done(scan_done),
        .scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(total),
        .bmp_px_wr_en(px_valid),.bmp_px_data(pixel),.bmp_px_ready(px_ready),.bmp_load_done(load_done),
        .bmp_load_error(load_error),.bmp_progress(progress),.write_abort(),.write_abort_ack(1'b0),
        .publish_req(),.publish_ack(1'b0),.error(player_error));
    always @(negedge clk) if(!rst) begin
        if(sector_error) $fatal(1,"delayed card falsely rejected: LBA=%d detail=%h",address,read_diagnostic);
        if(init_error || load_error || player_error) $fatal(1,"scan integration error");
        if(found) begin
            if(found_sector!=found_count*1801 || total!=found_count+1)
                $fatal(1,"scan catalog index/LBA mismatch");
            found_count=found_count+1;
        end
        if(load_start && (load_sector!=0 || total!=4)) $fatal(1,"first image must load LBA 0 after four headers");
    end
    initial begin
        #11;rst=1;repeat(8) @(negedge clk);rst=0;
        wait(write_req);@(negedge clk);
        if(commands!=5 || found_count!=4 || load_sector!=0 || address!=0 || bmp.signature!=16'h4d42)
            $fatal(1,"first-header handoff mismatch");
        $display("PASS sd_scan: real SPI/BMP/player, >2ms token delay, four exact LBAs, first load 0, valid BMP header");
        $finish;
    end
    initial begin #30000000;$fatal(1,"scan watchdog");end
endmodule
