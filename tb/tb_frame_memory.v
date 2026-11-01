`timescale 1ns/1ps
module tb_frame_memory;
 parameter WIDTH=640,HEIGHT=480,REAL_MEMORY=0,FOUR_SLOTS=0;
 localparam N=WIDTH*HEIGHT;
 reg mc=0,sc=0,vc=0,rst=1;
 always #10 mc=~mc;always #5 sc=~sc;always #20 vc=~vc;
 wire shift;assign #8 shift=mc;
 wire initialized,refresh,busy,sv,wrbusy,rdbusy,we,re,wready,wack,wfinish,rack,rfinish,puback,display_valid,rv,merror,underflow;
 wire [31:0] wd,sd,rd;wire [20:0] wa,ra;wire [3:0] dm;
 reg wreq=0,abort_write=0,wen=0,rreq=0,ren=0,pub=0;
 wire abort_ack;
 reg [1:0] wb=0,pb=0;reg [31:0] data=0;
 integer i,j,tag=1,read_tag=1,got=0,writes=0,reads=0,finished=0,refreshes=0;
 reg checking=0;integer expected_index;
 function [31:0] pattern(input integer n,input integer t);
 pattern=32'ha5691200 ^ (n*32'h01010700) ^ (t*32'h39132100);
 endfunction
 sdram_write_ctrl #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT)) writer(
 .clk_sd(sc),.mem_clk(mc),.rst(rst),.Sdr_init_done(initialized),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
 .rd_busy(rdbusy),.wr_busy(wrbusy),.write_req(wreq),.write_req_ack(wack),.write_abort(abort_write),.write_abort_ack(abort_ack),
 .write_addr0(21'd0),.write_addr1(21'(N)),.write_addr2(21'(2*N)),.write_addr3(21'(3*N)),.write_len(21'(N)),
 .write_addr_idx(wb),.write_en(wen),.write_data(data),.write_ready(wready),.write_finish(wfinish),
 .App_wr_dm(dm),.App_wr_en(we),.App_wr_addr(wa),.App_wr_din(wd));
 sdram_read_ctrl reader(
 .mem_clk(mc),.clk_video(vc),.rst(rst),.Sdr_init_done(initialized),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
 .wr_busy(wrbusy),.rd_busy(rdbusy),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),
 .publish_req(pub),.publish_buf(pb),.publish_image(2'd0),.display_image(),.publish_ack(puback),.display_valid(display_valid),
 .read_addr0(21'd0),.read_addr1(21'(N)),.read_addr2(21'(2*N)),.read_addr3(21'(3*N)),.read_len(21'(N)),
 .Sdr_rd_en(sv),.Sdr_rd_dout(sd),.App_rd_en(re),.App_rd_addr(ra),
 .read_en(ren),.read_data(rd),.read_valid(rv),.memory_error(merror),.underflow(underflow));
 generate if(REAL_MEMORY) begin: physical
 sdram memory(.Clk(mc),.Clk_sft(shift),.Rst(rst),.Sdr_init_done(initialized),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
 .App_wr_en(we),.App_wr_addr(wa),.App_wr_dm(dm),.App_wr_din(wd),.App_rd_en(re),.App_rd_addr(ra),
 .Sdr_rd_en(sv),.Sdr_rd_dout(sd));
 defparam memory.sdram.CLOCK_PAD_DELAY=3;
 defparam memory.sdram.MODEL_TAC=5;
 initial force memory.sdram.memory.Debug=0;
 end else begin: application
 reg [31:0] words[0:4*N-1];
 reg [5:0] valids=0;reg [31:0] pipeline[0:5];integer tick=0,k;
 assign initialized=tick>50;
 assign busy=(tick%701)<12;
 assign refresh=(tick%701)<12;
 assign sv=valids[5];assign sd=pipeline[5];
 always @(posedge mc) begin
 tick=tick+1;valids<={valids[4:0],re};
 if(re) pipeline[0]<=words[ra];
 for(k=1;k<6;k=k+1) pipeline[k]<=pipeline[k-1];
 if(we) words[wa]<=wd;
 end
 end endgenerate
 always @(posedge mc) if(!rst) begin
   if(we && re) $fatal(1,"simultaneous memory owners");
   if(we) begin
     expected_index=(HEIGHT-1-(writes%N)/WIDTH)*WIDTH+(writes%N)%WIDTH;
     if(wa!==21'(wb*N+expected_index) || wd!==pattern(writes%N,tag))
       $fatal(1,"write address/data %0d addr=%0d expected=%0d got=%h",writes,wa,wb*N+expected_index,wd);
     writes=writes+1;
   end
   if(re) reads=reads+1;
   if(wfinish) finished=finished+1;
   if(refresh) refreshes=refreshes+1;
   if(merror) $fatal(1,"memory error state=%0d returned=%0d issued=%0d",reader.state,reader.returned,reader.issued);
 end
 always @(posedge vc) if(checking && rv) begin
   expected_index=(HEIGHT-1-got/WIDTH)*WIDTH+got%WIDTH;
   if(rd!==pattern(expected_index,read_tag)) $fatal(1,"read pixel=%0d got=%h expected=%h",got,rd,pattern(expected_index,read_tag));
   got=got+1;
 end
 task begin_write(input integer buffer,input integer t);
 begin
 wb=buffer;tag=t;@(negedge sc);wreq=1;wait(wack);@(negedge sc);wreq=0;wait(!wack);
 end endtask
 task feed(input integer size);
 integer p;
 begin
 for(p=0;p<size;p=p+1) begin
   @(negedge sc);wait(wready);data=pattern(p,tag);wen=1;
   @(negedge sc);wen=0;repeat(7) @(negedge sc);
 end
 end endtask
 task write_frame(input integer buffer,input integer t);
 integer old_finish;
 begin
 old_finish=finished;begin_write(buffer,t);feed(N);wait(finished>old_finish);
 end endtask
 task read_frame(input integer t);
 integer p;
 begin
 got=0;read_tag=t;@(negedge vc);rreq=1;wait(rack);@(negedge vc);rreq=0;wait(!rack);
 repeat(1000) @(negedge vc);checking=1;
 for(p=0;p<N;p=p+1) begin
   @(negedge vc);ren=1;
   if(p%WIDTH==WIDTH-1) begin @(negedge vc);ren=0;repeat(160) @(negedge vc);end
 end
 @(negedge vc);ren=0;repeat(10) @(negedge vc);checking=0;
 if(got!=N || underflow) $fatal(1,"frame count=%0d underflow=%b",got,underflow);
 end endtask
 task publish(input integer buffer);
 begin @(negedge sc);pb=buffer;pub=1;wait(puback);@(negedge sc);pub=0;wait(!puback);end endtask
 initial begin
 #103;rst=0;wait(initialized);repeat(100) @(negedge mc);
 // No reader may access unpublished memory.
 repeat(100) @(negedge mc);if(re || display_valid) $fatal(1,"unpublished read");
 write_frame(0,1);$display("Memory first frame written at %t",$time);if(writes!=N) $fatal(1,"write frame length");
 fork publish(0);read_frame(1);join
 // Writing buffer 1 must not affect repeated display of buffer 0.
 fork write_frame(1,2);read_frame(1);join
 if(writes!=2*N) $fatal(1,"second write length");
 fork publish(1);read_frame(2);join
 if(FOUR_SLOTS) begin
   fork write_frame(2,3);read_frame(2);join
   fork write_frame(3,4);read_frame(2);join
   for(j=0;j<4;j=j+1) begin
     fork publish(j);read_frame(j+1);join
   end
   if(writes!=4*N || refreshes==0) $fatal(1,"four slot writes/refresh");
   $display("PASS four slot memory: distinct SDRAM addresses, concurrent retained display, cached publication/readback");$finish;
 end
 // Partial producer frame is discarded before the next request is accepted.
 begin_write(0,3);feed(100);@(negedge sc);abort_write=1;
 wait(abort_ack);repeat(10) @(negedge sc);abort_write=0;wait(!abort_ack);
 if(writes!=2*N) $fatal(1,"partial reserved burst escaped");
 write_frame(0,4);
 fork publish(0);read_frame(4);join
 if(refreshes==0) $fatal(1,"no refresh tested");
 $display("PASS frame memory: REAL_MEMORY=%0d, %0d writes %0d reads, flip, concurrent buffers, adoption, abort",REAL_MEMORY,writes,reads);$finish;
 end
 initial begin #400000000;$fatal(1,"memory timeout wstate=%0d rstate=%0d writes=%0d got=%0d",writer.state,reader.state,writes,got);end
endmodule
