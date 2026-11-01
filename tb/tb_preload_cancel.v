`timescale 1ns/1ps
module tb_preload_cancel;
    reg clk=0,rst=1,next_key=0,prev_key=0,finish=0,scan_done=0,found=0,done=0,bad=0,ack=0,abort_ack=0;
    always #5 clk=~clk;
    reg [31:0] sector=0;
    reg [2:0] total=0;
    wire scan,start,abort_load,wabort,pub,valid,error,preloaded,fade;
    wire [31:0] address;
    wire [1:0] wb,db,current,target;
    wire [3:0] bad_slots;
    wire cancel_abort;
    integer loads=0,aborts=0,i;
    reg error_seen=0;
    sd_player #(.CLK_FREQ_HZ(1000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),.RETRY_INPUT(1),.SKIP_BAD(1),.PROGRESS_TIMEOUT(10000)) dut(
        .clk(clk),.rst(rst),.retry_load(1'b0),.key_next(next_key),.key_prev(prev_key),.key_auto(1'b0),.period_select(2'd0),.sd_init_done(1'b1),
        .current_image(current),.target_image(target),.auto_enabled(),.display_valid(valid),.state_code(),.write_finish_t(finish),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),.write_buf_idx(wb),.disp_buf_idx(db),
        .bmp_write_req(1'b0),.bmp_write_req_ack(),.scan_start(scan),.load_start(start),.load_abort(abort_load),.load_sector(address),
        .bmp_ready(1'b1),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),.bmp_load_done(done),.bmp_load_error(bad),.bmp_progress(1'b0),
        .write_abort(wabort),.write_abort_ack(abort_ack),.publish_req(pub),.publish_ack(ack),.publish_fade(fade),.error(error),.load_success(),.preload_done(preloaded),
        .catalog_complete(1'b1),.catalog_continue(),.bad_slots(bad_slots),.select_request(1'b0),.select_index(2'd0),.browse_active(1'b0),
        .cached_slots(),.catalog_slots(),.control_busy(),.cancel_abort(cancel_abort));
    always @(negedge clk) begin
        if(start) loads=loads+1;
        if(error) error_seen=1;
    end
    always @(posedge abort_load) aborts=aborts+1;
    // cancel_abort covers the decoder's abort error window: set with the abort,
    // held until the next load_start, never set by a real load failure.
    reg start_q=0;
    always @(posedge clk) begin
        if(start_q && cancel_abort) $fatal(1,"cancel_abort still set after load_start");
        if(abort_load && !cancel_abort) $fatal(1,"abort without cancel_abort");
        start_q<=start;
    end
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task finish_load(input integer image);
        begin
            wait(dut.state==3);tick(2);
            if(target!=image || wb!=image || address!=100+image || (valid && wb==db))
                $fatal(1,"load overwrites display or wrong image/slot");
            done=1;tick(1);done=0;tick(8);finish=~finish;
        end
    endtask
    task adopt(input integer image,expected_fade);
        begin
            wait(pub);tick(6);if(wb!=image) $fatal(1,"publication wrong slot");
            if(fade!==expected_fade) $fatal(1,"publication style");
            ack=1;wait(!pub);tick(5);
            if(current!=image || db!=image || !valid) $fatal(1,"adoption metadata");
            ack=0;wait(dut.state==2);
        end
    endtask
    // Press during an unfinished background load: abort handshake, no error, no bad slot.
    task cancel_with(input integer image,input prev);
        begin
            wait(dut.state==3 && target==image);tick(3);
            if(!dut.background_load) $fatal(1,"expected a background preload");
            if(prev) prev_key=1;else next_key=1;tick(1);prev_key=0;next_key=0;
            tick(2);if(!wabort || !abort_load) $fatal(1,"key press did not abort the background load");
            abort_ack=1;wait(!wabort);tick(1);abort_ack=0;
            tick(2);if(dut.cached[image]) $fatal(1,"cancelled frame cached");
        end
    endtask
    initial begin
        tick(4);rst=0;wait(scan);tick(1);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;tick(1);end
        found=0;scan_done=1;
        finish_load(0);adopt(0,0);
        // Next while slot 1 preloads and nothing else is cached: slot 1 becomes a foreground load.
        cancel_with(1,0);
        finish_load(1);adopt(1,1);
        finish_load(2);wait(dut.cached[2]);
        if(current!=1 || pub) $fatal(1,"background load changed display");
        // Previous while slot 3 preloads: cached slot 0 is shown at once, then slot 3 reloads.
        cancel_with(3,1);
        adopt(0,1);
        finish_load(3);wait(preloaded);tick(8);
        if(loads!=6 || aborts!=2) $fatal(1,"load/abort count %0d/%0d",loads,aborts);
        if(error_seen || bad_slots!=0 || current!=0) $fatal(1,"cancel reported a fault or marked a bad slot");
        $display("PASS preload_cancel: key press aborts an unfinished background preload without fault, cached frame shown at once, uncached target loads in front, dropped slot preloaded again");
        $finish;
    end
    initial begin #200000;$fatal(1,"preload_cancel watchdog");end
endmodule
