`timescale 1ns/1ps
module tb_bmp_decoder;
 reg clk=0,rst=1,init=0,scan=0,start=0,abort_load=0,ack=0,px_ready=1;
 always #5 clk=~clk;
 wire ready,req,scan_done,found,wreq,valid,done,error,progress;
 wire [31:0] addr,found_sector; wire [2:0] total; wire [23:0] rgb;
 reg [7:0] data=0; reg dv=0,ending=0,busy=0,sec_error=0;
 integer offset=54,base=10,short_read=0,bad_header=0,service=-1,bytes_sent=0;
 integer pixels=0,requests=0,cycle=0,found_count=0;
 reg [31:0] service_addr; reg last_req=0;
 bmp_decoder #(.SCAN_START(0),.SCAN_MAX(3)) dut(
 .clk(clk),.rst(rst),.sd_init_done(init),.ready(ready),
 .sd_sec_read(req),.sd_sec_addr(addr),.sd_sec_data(data),.sd_sec_data_valid(dv),
 .sd_sec_end(ending),.sd_sec_busy(busy),.sd_sec_error(sec_error),
 .bmp_width(16'd640),.bmp_height(16'd480),.scan_start(scan),.scan_done(scan_done),
 .scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(total),
 .load_start(start),.load_abort(abort_load),.load_sector(32'd10),
 .write_req(wreq),.write_req_ack(ack),.px_wr_en(valid),.px_data(rgb),.px_ready(px_ready),
 .load_done(done),.load_error(error),.progress(progress),.state_code());
 function [23:0] pixel(input integer n);
   pixel={8'((n/640)^8'ha6),8'(n*3+7),8'(n^8'h59)};
 endfunction
 function [7:0] byte_value(input integer sector,input integer b);
 integer p,n,k,v;
 begin
 p=(sector-base)*512+b; byte_value=0;
 if(p>=offset && p<offset+921600) begin n=(p-offset)/3;k=(p-offset)%3;byte_value=(pixel(n)>>(k*8));end
 if(sector==base) begin
 case(b)
 0:byte_value=bad_header?0:8'h42;1:byte_value=8'h4d;
 14:byte_value=40;18:byte_value=8'h80;19:byte_value=2;
 22:byte_value=8'he0;23:byte_value=1;26:byte_value=1;28:byte_value=24;
 endcase
 if(b>=2 && b<=5) byte_value=(offset+921600)>>((b-2)*8);
 if(b>=10 && b<=13) byte_value=offset>>((b-10)*8);
 end
 end endfunction
 always @(negedge clk) begin
 cycle=cycle+1;px_ready=(cycle%11<7);
 ack=wreq;
 dv=0;ending=0;
 if(service>=0) begin
   if(service<(short_read?511:512)) begin
     dv=1;data=byte_value(service_addr,service);service=service+1;
   end else begin ending=1;busy=0;service=-1;end
 end else if(req) begin
   if(busy || last_req) $fatal(1,"sector request repeated/busy");
   requests=requests+1;busy=1;service_addr=addr;service=0;
 end
 last_req=req;
 end
 always @(posedge clk) if(!rst) begin
 if(valid && px_ready) begin
   if(rgb!==pixel(pixels)) $fatal(1,"BMP pixel %0d got %h expected %h",pixels,rgb,pixel(pixels));
   pixels=pixels+1;
 end
 if(found) begin
   found_count=found_count+1;
   if(found_sector!=1 || total!=1) $fatal(1,"scan LUT metadata");
 end
 end
 task load;
 begin wait(ready);@(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);end endtask
 initial begin
 #41;rst=0;repeat(8) @(negedge clk);
 if(ready || req) $fatal(1,"started before SD init");
 init=1;base=1;scan=1;@(negedge clk);scan=0;wait(scan_done);repeat(2) @(negedge clk);
 if(total!=1 || found_count!=1 || requests!=2) $fatal(1,"scan did not skip complete contiguous BMP");
 base=10;requests=0;pixels=0;load();
 if(error || pixels!=307200 || requests!=1801) $fatal(1,"54-byte offset count %0d req %0d",pixels,requests);
 offset=700;requests=0;pixels=0;load();
 if(error || pixels!=307200 || requests!=1802) $fatal(1,"700-byte offset count %0d req %0d",pixels,requests);
 bad_header=1;pixels=0;load();if(!error || pixels!=0) $fatal(1,"bad BM accepted");bad_header=0;
 short_read=1;load();if(!error || pixels!=0) $fatal(1,"short sector accepted");short_read=0;
 wait(ready);@(negedge clk);start=1;@(negedge clk);start=0;
 wait(pixels==100);@(negedge clk);abort_load=1;repeat(600) @(negedge clk);
 abort_load=0;wait(ready);pixels=0;requests=0;load();
 if(error || pixels!=307200) $fatal(1,"abort recovery failed");
 $display("PASS BMP: scan, 3 full frames, arbitrary offset, backpressure, invalid/short sectors, abort recovery");$finish;
 end
 initial begin #200000000;$fatal(1,"BMP timeout state=%0d pixels=%0d",dut.state,pixels);end
endmodule
