`timescale 1ns/1ps
module tb_memory_fault;
 reg mc=0,vc=0,rst=1,req=0,pub=0,sv=0;always #10 mc=~mc;always #20 vc=~vc;
 wire ack,puback,display_valid,re,error,uf;
 sdram_read_ctrl #(.RETURN_TIMEOUT(32)) dut(
 .mem_clk(mc),.clk_video(vc),.rst(rst),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.wr_busy(1'b0),.rd_busy(),
 .read_req(req),.read_req_ack(ack),.read_finish(),.publish_req(pub),.publish_buf(2'd0),.publish_image(2'd0),.display_image(),.publish_ack(puback),.display_valid(display_valid),
 .read_addr0(21'd0),.read_addr1(21'd512),.read_addr2(21'd0),.read_addr3(21'd0),.read_len(21'd256),
 .Sdr_rd_en(sv),.Sdr_rd_dout(32'hbad),.App_rd_en(re),.App_rd_addr(),.read_en(1'b0),.read_data(),.read_valid(),.memory_error(error),.underflow(uf));
 initial begin
 #111;rst=0;@(negedge vc);pub=1;repeat(10) @(negedge vc);req=1;
 wait(ack);@(negedge vc);req=0;pub=0;wait(!ack);wait(error);
 if(display_valid) $fatal(1,"failed memory still displayed");
 @(negedge vc);req=1;pub=1;sv=1;repeat(600) begin @(negedge vc);if(re || display_valid) $fatal(1,"late return contaminated a new frame");end
 rst=1;@(negedge vc);rst=0;req=0;pub=0;sv=0;repeat(20) @(negedge vc);if(error) $fatal(1,"reset did not clear memory fault");
 $display("PASS memory fault: timeout, no reuse after late responses, common-reset recovery");$finish;
 end
 initial begin #100000;$fatal(1,"fault watchdog");end
endmodule
