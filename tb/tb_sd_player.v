`timescale 1ns/1ps
module tb_sd_player;
 reg clk=0,rst=1,kn=1,ka=1,init=0,finish=0,ready=0,scan_done=0,found=0;
 reg [31:0] sector=0;reg [2:0] total=0;
 reg done=0,error_in=0,progress=0,abort_ack=0,pub_ack=0;
 wire scan,start,abort_load,wabort,pub,display_valid,err;wire[31:0] load_sector;
 wire[1:0] wb,db;integer loads=0,i,cycle=0;
 always #5 clk=~clk;
 sd_player #(.CLK_FREQ_HZ(1000),.AUTO_MS(40),.DEBOUNCE_MS(3),.PROGRESS_TIMEOUT(50)) dut(
 .clk(clk),.rst(rst),.key_next(kn),.key_auto(ka),.sd_init_done(init),.key_prev(1'b0),.period_select(2'd0),.current_image(),.target_image(),.auto_enabled(),
 .display_valid(display_valid),.state_code(),.write_finish_t(finish),
 .write_req(),.write_req_ack(1'b0),.write_en(),.write_data(),.write_ready(1'b1),
 .write_buf_idx(wb),.disp_buf_idx(db),.bmp_write_req(1'b0),.bmp_write_req_ack(),
 .scan_start(scan),.load_start(start),.load_abort(abort_load),.load_sector(load_sector),
 .bmp_ready(ready),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
 .bmp_px_wr_en(1'b0),.bmp_px_data(24'd0),.bmp_px_ready(),
 .bmp_load_done(done),.bmp_load_error(error_in),.bmp_progress(progress),
 .write_abort(wabort),.write_abort_ack(abort_ack),.publish_req(pub),.publish_ack(pub_ack),.error(err));
 always @(posedge clk) if(!rst) begin cycle=cycle+1;if(start) loads=loads+1;end
 task next_key;
 begin @(negedge clk);kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);end endtask
 task complete(input integer image,input integer buffer);
 begin
 wait(dut.state==3);
 if(load_sector!=100+image*1801 || wb!=buffer) $fatal(1,"image LUT/order image=%0d addr=%0d buffer=%0d",image,load_sector,wb);
 // Loading may take many timeout windows when it keeps making progress.
 repeat(100) begin @(negedge clk);progress=1;@(negedge clk);progress=0;end
 if(wabort || pub) $fatal(1,"progress timed out/published early");
 done=1;@(negedge clk);done=0;
 repeat(15) @(negedge clk);if(pub) $fatal(1,"published before memory completion");
 finish=~finish;wait(pub);
 repeat(30) @(negedge clk);
 if(wb!=buffer || (display_valid && db==buffer)) $fatal(1,"buffer prematurely released");
 pub_ack=1;wait(!pub);
 if(!display_valid || db!=buffer || dut.current_image!=image) $fatal(1,"publication metadata");
 repeat(10) @(negedge clk);pub_ack=0;wait(dut.state==2);
 end endtask
 initial begin
 #31;rst=0;ready=1;repeat(20) @(negedge clk);
 if(scan || loads) $fatal(1,"scan before init");init=1;wait(scan);
 @(negedge clk);
 for(i=1;i<=4;i=i+1) begin found=1;total=i;sector=100+(i-1)*1801;@(negedge clk);found=0;@(negedge clk);end
 scan_done=1;complete(0,0);
 // A short bounce must not load another image.
 @(negedge clk);kn=0;@(negedge clk);kn=1;repeat(10) @(negedge clk);
 if(loads!=1) $fatal(1,"key bounce accepted");
 next_key();complete(1,1);
 next_key();wait(dut.state==3);
 error_in=1;done=1;@(negedge clk);done=0;wait(wabort);
 if(db!=1 || !abort_load || pub) $fatal(1,"error lost displayed frame");
 repeat(10) @(negedge clk);abort_ack=1;wait(!wabort);@(negedge clk);abort_ack=0;error_in=0;
 wait(dut.state==2);next_key();complete(2,0);
 // AUTO_MS=40 must be honored, and enabling must clear a stale counter.
 @(negedge clk);ka=0;wait(dut.auto_play);@(negedge clk);ka=1;
 repeat(35) @(negedge clk);if(dut.state!=2) $fatal(1,"auto interval too short");
 wait(dut.state==3);@(negedge clk);ka=0;repeat(8) @(negedge clk);ka=1;
 complete(3,1);next_key();complete(0,0);
 // A producer which stops making progress must abort and return to idle.
 next_key();wait(wabort);@(negedge clk);abort_ack=1;wait(!wabort);
 @(negedge clk);abort_ack=0;wait(dut.state==2);
 if(!err || db!=0) $fatal(1,"timeout cleanup");
 $display("PASS player: init, 4-entry LUT, debounce, ordered/wrapped images, progress timeout, auto interval, publish/abort");$finish;
 end
 initial begin #200000;$fatal(1,"player watchdog state=%0d auto=%0d count=%0d pending=%0d",dut.state,dut.auto_play,dut.auto_count,dut.request_pending);end
endmodule
