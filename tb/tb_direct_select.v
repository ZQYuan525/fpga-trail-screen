`timescale 1ns/1ps
module tb_direct_select;
    reg clk=0,rst=1,scan_done=0,found=0,done=0,finish=0,ack=0,select_req=0,browse=0,auto_key=0;
    reg [2:0] total=0;reg [31:0] sector=0;reg [1:0] index=0;
    always #5 clk=~clk;
    wire scan,start,pub,ready,fade,busy;wire [1:0] current,target;wire [3:0] cached,catalog;
    integer loads=0,i;
    sd_player #(.CLK_FREQ_HZ(1000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),.SKIP_BAD(1),.DIRECT_SELECT(1),.PROGRESS_TIMEOUT(10000)) dut(
        .clk(clk),.rst(rst),.key_next(1'b0),.key_prev(1'b0),.key_auto(auto_key),.period_select(2'd0),.sd_init_done(1'b1),.retry_load(1'b0),
        .select_request(select_req),.select_index(index),.browse_active(browse),.cached_slots(cached),.catalog_slots(catalog),.control_busy(busy),
        .current_image(current),.target_image(target),.auto_enabled(),.display_valid(),.state_code(),.write_finish_t(finish),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),.write_buf_idx(),.disp_buf_idx(),
        .bmp_write_req(1'b0),.bmp_write_req_ack(),.scan_start(scan),.load_start(start),.load_abort(),.load_sector(),
        .bmp_ready(!ready),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),.bmp_load_done(done),.bmp_load_error(1'b0),.bmp_progress(1'b0),
        .write_abort(),.write_abort_ack(1'b0),.publish_req(pub),.publish_ack(ack),.publish_fade(fade),.error(),.load_success(),.preload_done(ready),
        .catalog_complete(1'b1),.catalog_continue(),.bad_slots());
    always @(negedge clk) if(start) loads=loads+1;
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task choose(input [1:0] n);begin @(negedge clk);index=n;select_req=1;tick(1);select_req=0;end endtask
    task adopt(input [1:0] n);begin
        wait(pub);tick(5);if(target!=n) $fatal(1,"wrong direct target");
        ack=1;wait(!pub);tick(4);ack=0;wait(!busy);tick(2);
        if(current!=n) $fatal(1,"wrong committed image");
    end endtask
    initial begin
        tick(4);rst=0;wait(scan);tick(1);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;tick(1);end
        found=0;scan_done=1;
        choose(3); // Not cached yet: must not queue a request.
        for(i=0;i<4;i=i+1) begin
            wait(dut.state==3);tick(2);done=1;tick(1);done=0;tick(3);
            if(cached[i]) $fatal(1,"cached before SDRAM complete");
            finish=~finish;
            if(i==0) adopt(0);else wait(cached[i]);
        end
        wait(ready);tick(10);if(current!=0 || catalog!=15) $fatal(1,"invalid early request escaped");
        auto_key=1;tick(1);auto_key=0;browse=1;tick(2200);
        if(pub || current!=0 || !dut.auto_play) $fatal(1,"browse failed to pause auto");
        choose(3);wait(pub);if(!fade) $fatal(1,"direct request did not use fade");
        choose(1);choose(2); // Most recent target queued during publication.
        adopt(3);adopt(2);tick(10);
        choose(2);tick(20);if(pub || busy) $fatal(1,"same-image request stuck");
        if(loads!=4 || current!=2) $fatal(1,"selection reread storage");
        browse=0;adopt(3);if(fade) $fatal(1,"autoplay style changed");
        $display("PASS direct_select: incomplete rejection, complete cache masks, direct target, newest pending target, no SD reread, same-image exit, browse pause/resume");$finish;
    end
    initial begin #200000;$fatal(1,"direct select timeout");end
endmodule
