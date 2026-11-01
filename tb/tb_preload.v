`timescale 1ns/1ps
module tb_preload;
    reg clk=0,rst=1,next_key=0,prev_key=0,finish=0,scan_done=0,found=0,done=0,bad=0,ack=0,abort_ack=0,retry=0;
    always #5 clk=~clk;
    reg [31:0] sector=0;
    reg bmp_ready=1;
    reg auto_key=0;
    reg [2:0] total=0;
    wire scan,start,abort_load,wabort,pub,valid,error,preloaded,fade;
    wire [31:0] address;
    wire [1:0] wb,db,current,target;
    integer loads=0,i;
    sd_player #(.CLK_FREQ_HZ(1000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),.RETRY_INPUT(1),.PROGRESS_TIMEOUT(10000)) dut(
        .clk(clk),.rst(rst),.retry_load(retry),.key_next(next_key),.key_prev(prev_key),.key_auto(auto_key),.period_select(2'd0),.sd_init_done(1'b1),
        .current_image(current),.target_image(target),.auto_enabled(),.display_valid(valid),.state_code(),.write_finish_t(finish),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),.write_buf_idx(wb),.disp_buf_idx(db),
        .bmp_write_req(1'b0),.bmp_write_req_ack(),.scan_start(scan),.load_start(start),.load_abort(abort_load),.load_sector(address),
        .bmp_ready(bmp_ready),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),.bmp_load_done(done),.bmp_load_error(bad),.bmp_progress(1'b0),
        .write_abort(wabort),.write_abort_ack(abort_ack),.publish_req(pub),.publish_ack(ack),.publish_fade(fade),.error(error),.load_success(),.preload_done(preloaded));
    always @(negedge clk) if(start) loads=loads+1;
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task finish_load(input integer image);
        begin
            wait(dut.state==3);tick(2);
            if(target!=image || wb!=image || address!=100+image || (valid && wb==db))
                $fatal(1,"preload overwrites display or wrong image/slot");
            done=1;tick(1);done=0;tick(8);
            if(pub || dut.cached[image]) $fatal(1,"incomplete memory frame cached");
            finish=~finish;
        end
    endtask
    task adopt(input integer image,expected_fade);
        begin
            wait(pub);tick(6);if(wb!=image) $fatal(1,"cached publication wrong slot");
            if(fade!==expected_fade) $fatal(1,"cached publication style");
            ack=1;wait(!pub);tick(5);
            if(current!=image || db!=image || !valid) $fatal(1,"cached adoption metadata");
            ack=0;wait(dut.state==2);
        end
    endtask
    initial begin
        tick(4);rst=0;wait(scan);tick(1);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;tick(1);end
        found=0;scan_done=1;
        finish_load(0);adopt(0,0);
        finish_load(1);wait(dut.cached[1]);
        if(current!=0 || pub || fade) $fatal(1,"background load changed display/style");
        wait(dut.state==3);tick(2);bad=1;done=1;tick(1);done=0;wait(wabort);
        if(dut.cached[2] || current!=0 || !valid) $fatal(1,"failed background image changed cache/display");
        if(dut.cancel_abort) $fatal(1,"real load failure marked as key cancel");
        abort_ack=1;wait(!wabort);tick(1);abort_ack=0;bad=0;wait(dut.state==2);
        @(negedge clk);retry=1;tick(1);retry=0;finish_load(2);wait(dut.cached[2]);
        finish_load(3);wait(preloaded);tick(8);
        if(loads!=5 || current!=0) $fatal(1,"preload count including same-slot retry");
        // WAV owns the shared card after preload. BMP readiness stays low;
        // cached publication must remain independent of storage availability.
        bmp_ready=0;tick(8);
        for(i=1;i<=5;i=i+1) begin next_key=1;tick(1);next_key=0;adopt(i%4,1);tick(4);end
        prev_key=1;tick(1);prev_key=0;adopt(0,1);tick(10);
        auto_key=1;tick(1);auto_key=0;adopt(1,0);adopt(2,0);
        tick(1);auto_key=1;tick(1);auto_key=0;tick(1010);
        if(current!=2 || pub) $fatal(1,"cached autoplay did not stop");
        if(loads!=5 || error || !preloaded) $fatal(1,"cached switch reread card");
        $display("PASS preload: four independent slots, memory-complete validity, background retry, cached next/previous/wrap/autoplay while storage unavailable");
        $finish;
    end
    initial begin #100000;$fatal(1,"preload watchdog");end
endmodule
