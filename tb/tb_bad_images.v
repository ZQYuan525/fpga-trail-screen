`timescale 1ns/1ps
module tb_bad_images;
    reg clk=0,rst=1,found=0,scan_done=0,done=0,bad=0,finish=0,ack=0,aack=0,key=0,prev=0;
    always #5 clk=~clk;
    reg [2:0] total=0;
    reg [31:0] sector=0;
    wire scan,start,abort_load,wabort,pub,valid,error,preloaded;
    wire [3:0] bad_slots;
    wire [1:0] target,current;
    integer loads[0:3];integer i;reg all_bad=0;
    sd_player #(.CLK_FREQ_HZ(1000),.KEY_EVENTS(1),.RUNTIME_CONTROL(1),.PRELOAD(1),
        .SKIP_BAD(1),.BAD_RETRIES(1),.PROGRESS_TIMEOUT(10000)) dut(
        .clk(clk),.rst(rst),.retry_load(1'b0),.key_next(key),.key_prev(prev),.key_auto(1'b0),.period_select(2'd0),.sd_init_done(1'b1),
        .current_image(current),.target_image(target),.display_valid(valid),.write_finish_t(finish),
        .write_req_ack(1'b0),.write_ready(1'b1),.bmp_write_req(1'b0),.scan_start(scan),.load_start(start),
        .bmp_ready(1'b1),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .load_abort(abort_load),.bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_load_done(done),.bmp_load_error(bad),.bmp_progress(1'b0),
        .write_abort(wabort),.write_abort_ack(aack),.publish_req(pub),.publish_ack(ack),.error(error),.preload_done(preloaded),.bad_slots(bad_slots));
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    // Emulate source failures and complete writer cancellation; never fake publication.
    always @(negedge clk) begin
        done=0;bad=0;
        if(!rst && start) begin
            loads[target]=loads[target]+1;
            done=1;bad=all_bad || (target==0 || target==2);
            if(!bad) finish=~finish;
        end
        aack=wabort;ack=pub;
    end
    initial begin
        for(i=0;i<4;i=i+1) loads[i]=0;
        tick(4);rst=0;wait(scan);tick(1);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;tick(1);end
        found=0;scan_done=1;tick(1);scan_done=0;
        wait(preloaded);tick(12);
        if(bad_slots!=4'b0101 || !valid || current!=1 || loads[0]!=2 || loads[2]!=2 || loads[1]!=1 || loads[3]!=1)
            $fatal(1,"bad images did not retire: bad=%b current=%d loads=%d,%d,%d,%d",bad_slots,current,loads[0],loads[1],loads[2],loads[3]);
        key=1;tick(1);key=0;wait(current==3);tick(10);
        key=1;tick(1);key=0;wait(current==1);tick(10);
        prev=1;tick(1);prev=0;wait(current==3);tick(10);
        if(loads[0]!=2 || loads[2]!=2 || error) $fatal(1,"navigation retried quarantined slot");
        rst=1;key=0;prev=0;all_bad=1;scan_done=0;found=0;total=0;tick(4);
        for(i=0;i<4;i=i+1) loads[i]=0;
        rst=0;wait(scan);tick(1);
        for(i=0;i<4;i=i+1) begin found=1;total=i+1;sector=100+i;tick(1);end
        found=0;scan_done=1;tick(1);scan_done=0;
        wait(preloaded);tick(30);
        if(valid || bad_slots!=15 || !error) $fatal(1,"all-bad catalog did not terminate with diagnostic and media-ready");
        for(i=0;i<4;i=i+1) if(loads[i]!=2) $fatal(1,"all-bad retry bound");
        $display("PASS bad_images: all-bad catalog terminates; failed first/background slots retire after bounded retries; good frames and media-ready survive; navigation skips failures");
        $finish;
    end
    initial begin #1000000;$fatal(1,"bad image recovery timeout");end
endmodule
