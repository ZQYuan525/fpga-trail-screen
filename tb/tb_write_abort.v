`timescale 1ns/1ps
module tb_write_abort;
 reg sc=0,mc=0,rst=1,req=0,abort_write=0,en=0,stop_send=0;
 always #5 sc=~sc;always #10 mc=~mc;
 reg [31:0] data=0;wire ready,ack,abort_ack,finish,we,busy;
 wire [20:0] addr;wire [31:0] wd;integer writes=0,tag=1,finishes=0;
 sdram_write_ctrl #(.WRITE_V_FLIP(0)) dut(
 .clk_sd(sc),.mem_clk(mc),.rst(rst),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.rd_busy(1'b0),.wr_busy(busy),
 .write_req(req),.write_req_ack(ack),.write_abort(abort_write),.write_abort_ack(abort_ack),
 .write_addr0(21'd0),.write_addr1(21'd512),.write_addr2(21'd0),.write_addr3(21'd0),.write_len(21'd512),.write_addr_idx(2'd0),
 .write_en(en),.write_data(data),.write_ready(ready),.write_finish(finish),
 .App_wr_dm(),.App_wr_en(we),.App_wr_addr(addr),.App_wr_din(wd));
 always @(posedge mc) if(!rst) begin
 if(we) begin
 if(addr!==21'(writes) || wd!==(32'(tag*65536+writes))) $fatal(1,"abort/reload stale word: index=%0d addr=%0d data=%h",writes,addr,wd);
 writes=writes+1;
 end
 if(finish) finishes=finishes+1;
 end
 task request_frame;
 begin @(negedge sc);req=1;wait(ack);@(negedge sc);req=0;wait(!ack);end endtask
 task send_frame;
 integer p;
 begin
 for(p=0;p<512 && !stop_send;p=p+1) begin
 @(negedge sc);while(!ready && !stop_send) @(negedge sc);
 if(!stop_send) begin data=tag*65536+p;en=1;end
 end
 @(negedge sc);en=0;
 end endtask
 initial begin
 #113;rst=0;request_frame();
 fork
 send_frame();
 begin wait(writes>=16);@(negedge sc);stop_send=1;abort_write=1;wait(abort_ack);end
 join
 repeat(8) @(negedge sc);
 if(we || finishes || writes<16 || writes>=256) $fatal(1,"midburst abort did not stop/reserved frame finished");
 abort_write=0;wait(!abort_ack);repeat(8) @(negedge sc);
 writes=0;tag=2;stop_send=0;request_frame();send_frame();wait(finishes==1);
 if(writes!=512) $fatal(1,"reloaded frame not complete");
 $display("PASS write abort: cancel inside active burst, flush pending words, clean 512-word reload");$finish;
 end
 initial begin #100000;$fatal(1,"write abort watchdog");end
endmodule
