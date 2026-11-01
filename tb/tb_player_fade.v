`timescale 1ns/1ps
// Real producer + fade controller + SDRAM reader + vendor FIFO. Only BMP
// completion and the memory return bus are transactional models here.
module tb_player_fade;
    reg cclk=0,mclk=0,pclk=0,rst=1;
    always #5 cclk=~cclk;always #11 mclk=~mclk;always #19 pclk=~pclk;
    reg kn=0,kp=0,ka=0,scan_done=0,found=0,done=0,finish=0;
    reg [2:0] total=0;reg [31:0] sector=0;
    wire scan,start,pub,style,pack,mreq,mack,preloaded,valid,err;
    wire [1:0] wb,current,target,displayed;
    reg bmp_ready=1;integer loads=0,load_delay=0,i,n,commits=0,frames=0,wipe_boundary;
    reg vs=0,rreq=0,ren=0,ret=0;
    reg [31:0] retdata=0;wire [31:0] data;
    wire rack,rfinish,cmd,rv,merror,underflow,display_valid;
    wire [20:0] addr;wire [4:0] gain;
    reg [1:0] expected_slot;
    sd_player #(.CLK_FREQ_HZ(10000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),.PROGRESS_TIMEOUT(10000)) player(
        .clk(cclk),.rst(rst),.retry_load(1'b0),.key_next(kn),.key_prev(kp),.key_auto(ka),.period_select(2'd0),.sd_init_done(1'b1),
        .current_image(current),.target_image(target),.display_valid(valid),.auto_enabled(),.state_code(),.write_finish_t(finish),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),.write_buf_idx(wb),.disp_buf_idx(),
        .bmp_write_req(1'b0),.bmp_write_req_ack(),.scan_start(scan),.load_start(start),.load_abort(),.load_sector(),
        .bmp_ready(bmp_ready),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),.bmp_load_done(done),.bmp_load_error(1'b0),.bmp_progress(1'b0),
        .write_abort(),.write_abort_ack(1'b0),.publish_req(pub),.publish_ack(pack),.publish_fade(style),.error(err),.load_success(),.preload_done(preloaded));
    frame_fade fade(.ctrl_clk(cclk),.ctrl_rst(rst),.pix_clk(pclk),.pix_rst(rst),
        .publish_req(pub),.publish_fade(style),.memory_ack(mack),.memory_req(mreq),.publish_ack(pack),.i_vs(vs),.fade_gain(gain));
    sdram_read_ctrl #(.BURST_SIZE(8),.WIPE_FRAMES(4),.MANUAL_FADE(1)) reader(
        .mem_clk(mclk),.clk_video(pclk),.rst(rst),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.wr_busy(1'b0),
        .rd_busy(),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),.publish_req(mreq),.publish_buf(wb),.publish_fade(style),
        .publish_image(target),.display_image(displayed),.publish_ack(mack),.display_valid(display_valid),
        .read_addr0(21'd0),.read_addr1(21'd64),.read_addr2(21'd128),.read_addr3(21'd192),.read_len(21'd24),
        .Sdr_rd_en(ret),.Sdr_rd_dout(retdata),.App_rd_en(cmd),.App_rd_addr(addr),.read_en(ren),.read_data(data),.read_valid(rv),
        .memory_error(merror),.underflow(underflow));
    always @(posedge mclk) begin ret<=!rst && cmd;if(cmd) retdata<=32'h2080e000+(addr<<8);end
    always @(negedge cclk) begin
        done=0;
        if(start) begin loads=loads+1;load_delay=8;end
        if(load_delay>0) begin
            load_delay=load_delay-1;
            if(load_delay==0) begin done=1;finish=~finish;end
        end
        if(!rst && pub && style && mreq && !mack && gain!=0) $fatal(1,"manual reader grant before black");
        if(!rst && pub && style && pack && gain!=16) $fatal(1,"queued producer released during fade");
        if(err || merror || underflow) $fatal(1,"integrated player/reader fault");
    end
    always @(posedge pack) if(!rst) commits=commits+1;
    // Each frame drives the original four-phase read request and consumes all
    // 24 actual FIFO pixels. Automatic wipe is checked against an external
    // six-word-per-frame reference; manual grant must select all 24 at once.
    initial begin
        wipe_boundary=0;wait(!rst);repeat(12) @(negedge pclk);
        forever begin
            @(negedge pclk);vs=1;rreq=1;
            wait(rack);@(negedge pclk);rreq=0;vs=0;wait(!rack);
            if(display_valid) begin
                wait(rfinish);
                if(mreq && !mack && !style) begin
                    wipe_boundary=wipe_boundary+6;
                end else wipe_boundary=0;
                for(n=0;n<24;n=n+1) begin
                    expected_slot=n<wipe_boundary?wb:displayed;
                    @(negedge pclk);ren=1;@(negedge pclk);ren=0;
                    if(!rv || data!==(32'h2080e000+((expected_slot*64+n)<<8)))
                        $fatal(1,"integration FIFO pixel frame=%0d pixel=%0d data=%h slot=%0d",frames,n,data,expected_slot);
                end
            end
            frames=frames+1;repeat(40) @(negedge pclk);
        end
    end
    task key(input integer direction);
        begin @(negedge cclk);kn=direction!=1;kp=direction!=0;
            @(negedge cclk);kn=0;kp=0;end
    endtask
    task settled(input integer image);
        begin wait(current==image && player.state==2);repeat(4) @(negedge cclk);end
    endtask
    initial begin
        #153;rst=0;wait(scan);@(negedge cclk);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;@(negedge cclk);end
        found=0;scan_done=1;@(negedge cclk);scan_done=0;
        wait(valid);if(style || gain!=16) $fatal(1,"startup unexpectedly faded");
        wait(preloaded);settled(0);bmp_ready=0;
        key(0);wait(pub);if(!style) $fatal(1,"manual style missing");
        wait(gain==10);key(0);key(1); // latest pending direction wins
        wait(current==1);settled(0);
        if(commits!=3) $fatal(1,"queued keys lost/duplicated commits=%0d",commits);
        key(1);settled(3);key(2);settled(0); // previous wrap; simultaneous next wins
        @(negedge cclk);ka=1;@(negedge cclk);ka=0;
        wait(pub);if(style || gain!=16) $fatal(1,"automatic must use wipe, not fade");
        @(negedge cclk);ka=1;@(negedge cclk);ka=0;settled(1);
        repeat(20) @(negedge pclk);
        if(loads!=4 || commits!=6) $fatal(1,"cached fade reread media or wrong commit count");
        $display("PASS player_fade: real player/fade/reader/FIFO, latest pending direction, next/previous wrap, auto wipe, no storage access during cached transitions");
        $finish;
    end
    initial begin #10000000;$fatal(1,"player fade watchdog state=%0d current=%0d gain=%0d",player.state,current,gain);end
endmodule
