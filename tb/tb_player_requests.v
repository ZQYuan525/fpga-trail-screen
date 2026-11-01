`timescale 1ns/1ps
module tb_player_requests;
    reg clk=0,rst=1,kn=0,kp=0,ka=0,finish=0,scan_done=0,found=0;
    reg [1:0] period=0;
    reg [31:0] sector=0;reg [2:0] total=0;
    reg done=0,bad=0,abort_ack=0,pub_ack=0,retry=0;
    wire scan,start,abort_load,wabort,pub,valid,err,auto_en;
    wire [31:0] address;wire [1:0] wb,db,current,target;
    integer loads=0,i,baseline;
    always #5 clk=~clk;
    sd_player #(.CLK_FREQ_HZ(1000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.RETRY_INPUT(1),.PROGRESS_TIMEOUT(100000)) dut(
        .clk(clk),.rst(rst),.retry_load(retry),.key_next(kn),.key_auto(ka),.key_prev(kp),.period_select(period),.sd_init_done(1'b1),
        .current_image(current),.target_image(target),.auto_enabled(auto_en),.display_valid(valid),.state_code(),.write_finish_t(finish),
        .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),
        .write_buf_idx(wb),.disp_buf_idx(db),.bmp_write_req(1'b0),.bmp_write_req_ack(),
        .scan_start(scan),.load_start(start),.load_abort(abort_load),.load_sector(address),
        .bmp_ready(1'b1),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),.bmp_load_done(done),.bmp_load_error(bad),.bmp_progress(1'b0),
        .write_abort(wabort),.write_abort_ack(abort_ack),.publish_req(pub),.publish_ack(pub_ack),.error(err));
    always @(negedge clk) if(start) loads=loads+1;
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task key(input integer direction);
        begin @(negedge clk);kn=direction==0 || direction==2;kp=direction==1 || direction==2;
            tick(1);kn=0;kp=0;tick(2);end
    endtask
    task auto_key;begin @(negedge clk);ka=1;tick(1);ka=0;end endtask
    task boot(input integer count);
        begin
            rst=1;kn=0;kp=0;ka=0;finish=0;pub_ack=0;abort_ack=0;done=0;bad=0;found=0;scan_done=0;period=0;total=0;
            tick(4);rst=0;wait(scan);@(negedge clk);
            for(i=1;i<=count;i=i+1) begin found=1;total=i;sector=100+i-1;tick(1);found=0;tick(1);end
            scan_done=1;tick(1);scan_done=0;tick(3);
        end
    endtask
    task complete(input integer image);
        begin
            wait(dut.state==3);tick(1);
            if(address!=100+image || target!=image) $fatal(1,"wrong target %0d expected %0d",target,image);
            done=1;tick(1);done=0;tick(4);if(pub) $fatal(1,"early publication");
            finish=~finish;wait(pub);tick(8);
            baseline=loads;tick(8);if(loads!=baseline) $fatal(1,"load during publish");
            pub_ack=1;wait(!pub);tick(3);
            if(current!=image || !valid) $fatal(1,"committed image mismatch");
            if(loads!=baseline) $fatal(1,"old buffer reused before ack release");
            pub_ack=0;wait(dut.state==2); // return before pending request can start
        end
    endtask
    initial begin
        boot(4);complete(0);key(1);complete(3); // wrap backwards
        key(0);key(0);key(1);key(0);key(1); // busy latest direction is previous
        complete(0);complete(3);tick(10);if(dut.state!=2) $fatal(1,"queued requests accumulated");
        key(2);complete(0); // simultaneous next wins
        key(0);key(0);bad=1;done=1;tick(1);done=0;wait(wabort);
        if(current!=0 || !abort_load) $fatal(1,"failed load changed current image");
        abort_ack=1;wait(!wabort);tick(1);abort_ack=0;bad=0;
        complete(1); // queued next is relative to still-displayed 0, not failed target
        // Runtime period changes restart the timer, including near its old deadline.
        auto_key();tick(990);if(dut.state!=2) $fatal(1,"one second interval too short");
        period=1;tick(2990);if(dut.state!=2) $fatal(1,"period update did not restart at three seconds");
        wait(dut.state==3);auto_key();complete(2);
        period=2;auto_key();tick(4990);if(dut.state!=2) $fatal(1,"five seconds interval");
        wait(dut.state==3);auto_key();complete(3);
        period=3;auto_key();tick(9990);if(dut.state!=2) $fatal(1,"ten seconds interval");
        wait(dut.state==3);auto_key();complete(0);
        boot(3);complete(0);key(1);complete(2);key(0);complete(0);
        boot(2);complete(0);key(1);complete(1);key(0);complete(0);
        boot(1);wait(dut.state==3);bad=1;done=1;tick(1);done=0;
        wait(wabort);abort_ack=1;wait(!wabort);tick(1);abort_ack=0;bad=0;wait(dut.state==2);
        @(negedge clk);retry=1;tick(1);retry=0;complete(0);
        baseline=loads;key(0);key(1);auto_key();tick(1100);
        if(loads!=baseline || auto_en) $fatal(1,"single-image repeated load");
        boot(0);baseline=loads;key(0);key(1);tick(20);
        if(valid || loads!=baseline) $fatal(1,"empty catalog load");
        retry=1;tick(1);retry=0;wait(scan);tick(1);
        found=1;total=1;sector=100;tick(1);found=0;scan_done=1;tick(1);scan_done=0;
        complete(0);
        $display("PASS player_requests: latest direction, wrap 2/3/4, empty/single, failure retry, release ownership, runtime 1/3/5/10s");$finish;
    end
    initial begin #1000000;$fatal(1,"request test timeout state=%0d",dut.state);end
endmodule
