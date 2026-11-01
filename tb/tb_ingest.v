`timescale 1ns/1ps
// Scaler/player/real FIFO/read-write integration with an application memory model.
module tb_ingest;
    localparam W=8,H=6,N=W*H;
    reg sc=0,mc=0,vc=0,rst=1;always #5 sc=~sc;always #10 mc=~mc;always #20 vc=~vc;
    reg next_key=0,bready=1,scan_done=0,found=0,breq=0,bvalid=0,bdone=0,topdown=0;
    reg [31:0] sector=0;reg [2:0] total=0;reg [15:0] sw=3,sh=2;reg [23:0] pixel_data=0;
    wire scan_start,load_start,load_abort,bak,br,sv,sr,sdone,serror,sidle;
    wire [23:0] scaled;
    wire wreq,wack,wen,wready,wfinish,abort_write,abort_ack,pub,pack,player_error;
    wire [31:0] wdata;wire [1:0] wb;
    wire [31:0] load_sector;
    reg request_d=0,finish_toggle=0;
    always @(posedge sc) request_d<=breq;
    always @(posedge mc) if(rst) finish_toggle<=0;else if(wfinish) finish_toggle<=~finish_toggle;
    bilinear_scaler #(.OUT_WIDTH(W),.OUT_HEIGHT(H),.MAX_WIDTH(16)) scaler(
        .clk(sc),.rst(rst),.start(breq && !request_d),.abort_load(load_abort),.source_width(sw),.source_height(sh),
        .in_valid(bvalid),.in_data(pixel_data),.in_ready(br),.in_done(bdone),.in_error(1'b0),
        .out_valid(sv),.out_data(scaled),.out_ready(sr),.done(sdone),.error(serror),.idle(sidle));
    sd_player #(.CLK_FREQ_HZ(100000),.KEY_EVENTS(1)) player(.clk(sc),.rst(rst),.key_next(next_key),.key_auto(1'b0),.sd_init_done(1'b1),.key_prev(1'b0),.period_select(2'd0),.current_image(),.target_image(),.auto_enabled(),
        .display_valid(),.state_code(),.write_finish_t(finish_toggle),.write_req(wreq),.write_req_ack(wack),
        .write_en(wen),.write_data(wdata),.write_ready(wready),.write_buf_idx(wb),.disp_buf_idx(),
        .bmp_write_req(breq),.bmp_write_req_ack(bak),.scan_start(scan_start),.load_start(load_start),.load_abort(load_abort),.load_sector(load_sector),
        .bmp_ready(bready && sidle),.scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(sector),.scan_found_total(total),
        .bmp_px_wr_en(sv),.bmp_px_data(scaled),.bmp_px_ready(sr),.bmp_load_done(sdone),.bmp_load_error(serror),.bmp_progress((bvalid && br)||(sv && sr)),
        .write_abort(abort_write),.write_abort_ack(abort_ack),.publish_req(pub),.publish_ack(pack),.error(player_error));
    wire wrbusy,rdbusy,we,re,rv,merror,underflow,rack,rfinish;
    wire [20:0] wa,ra;wire [31:0] wd,rd;wire [3:0] dm;
    reg rreq=0,ren=0,ret=0;reg [31:0] retdata=0;
    reg [31:0] memory[0:2*N-1];integer writes=0,tag=1,i,j;
    sdram_write_ctrl #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H),.DYNAMIC_ORIENTATION(1)) writer(
        .clk_sd(sc),.mem_clk(mc),.rst(rst),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.rd_busy(rdbusy),.wr_busy(wrbusy),
        .write_req(wreq),.write_req_ack(wack),.write_abort(abort_write),.write_abort_ack(abort_ack),
        .write_addr0(21'd0),.write_addr1(21'(N)),.write_addr2(21'd0),.write_addr3(21'd0),.write_len(21'(N)),.write_addr_idx(wb),
        .write_en(wen),.write_data(wdata),.write_ready(wready),.write_finish(wfinish),.App_wr_dm(dm),.App_wr_en(we),.App_wr_addr(wa),.App_wr_din(wd),.source_top_down(topdown));
    sdram_read_ctrl #(.WIPE_FRAMES(4)) reader(.mem_clk(mc),.clk_video(vc),.rst(rst),
        .Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.wr_busy(wrbusy),.rd_busy(rdbusy),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),
        .publish_req(pub),.publish_buf(wb),.publish_image(2'd0),.display_image(),.publish_ack(pack),.display_valid(),.read_addr0(21'd0),.read_addr1(21'(N)),.read_addr2(21'd0),.read_addr3(21'd0),.read_len(21'(N)),
        .Sdr_rd_en(ret),.Sdr_rd_dout(retdata),.App_rd_en(re),.App_rd_addr(ra),.read_en(ren),.read_data(rd),.read_valid(rv),.memory_error(merror),.underflow(underflow));
    function [23:0] pattern(input integer x,y,t);
        pattern={8'(x*13+y*7+t*20),8'(x*3+y*19+t*30),8'(x*9+y*11+t*40)};
    endfunction
    function integer mix(input integer a,b,f);mix=(a*(256-f)+b*f+128)/256;endfunction
    function [31:0] expected(input integer n,t);
        integer xx,yy,ww,hh,xf,yf,x0,y0,x1,y1,k,c0,c1,v;
        reg [23:0] a,b,c,d,result;
        begin
            ww=t==1?3:5;hh=t==1?2:3;xx=n%W;yy=t==1?H-1-n/W:n/W;
            xf=xx==W-1?(ww-1)*65536:xx*((ww-1)*65536/(W-1));
            yf=yy==H-1?(hh-1)*65536:yy*((hh-1)*65536/(H-1));
            x0=xf/65536;y0=yf/65536;x1=x0+1<ww?x0+1:x0;y1=y0+1<hh?y0+1:y0;
            a=pattern(x0,y0,t);b=pattern(x1,y0,t);c=pattern(x0,y1,t);d=pattern(x1,y1,t);result=0;
            for(k=0;k<3;k=k+1) begin
                c0=mix((a>>(k*8))&255,(b>>(k*8))&255,(xf>>8)&255);
                c1=mix((c>>(k*8))&255,(d>>(k*8))&255,(xf>>8)&255);
                v=mix(c0,c1,(yf>>8)&255);result=result|(v<<(k*8));
            end
            expected={result,8'd0};
        end
    endfunction
    always @(posedge mc) begin
        ret<=!rst && re;if(re) retdata<=memory[ra];
        if(!rst) begin
            if(we && re) $fatal(1,"ingest simultaneous memory owners");
            if(we) begin
                if(wa>=2*N || wd!==expected(wa%N,tag)) $fatal(1,"ingest scaled/oriented write addr=%d got=%h expected=%h",wa,wd,expected(wa%N,tag));
                memory[wa]<=wd;writes=writes+1;
            end
            if(pub && writes<tag*N) $fatal(1,"publication before final memory write");
            if(merror || player_error || underflow) $fatal(1,"ingest error");
        end
    end
    task source_frame(input integer t);
        begin
            wait(load_start);@(negedge sc);tag=t;sw=t==1?3:5;sh=t==1?2:3;topdown=t==2;bready=0;breq=1;
            wait(bak);@(negedge sc);breq=0;wait(!bak);
            for(i=0;i<sw*sh;i=i+1) begin
                @(negedge sc);bvalid=1;pixel_data=pattern(i%sw,i/sw,t);
                @(posedge sc);while(!br) @(posedge sc);
                @(negedge sc);bvalid=0;
            end
            bdone=1;@(negedge sc);bdone=0;bready=1;
        end
    endtask
    task read_frame(input integer boundary);
        begin
            @(negedge vc);rreq=1;wait(rack);@(negedge vc);rreq=0;wait(!rack);wait(rfinish);
            for(j=0;j<N;j=j+1) begin
                @(negedge vc);ren=1;@(negedge vc);ren=0;
                if(!rv || rd!==expected(j,j<boundary?2:1)) $fatal(1,"ingest display pixel=%d boundary=%d",j,boundary);
            end
        end
    endtask
    initial begin
        #123;rst=0;wait(scan_start);@(negedge sc);found=1;total=1;sector=0;
        @(negedge sc);total=2;sector=2;@(negedge sc);found=0;scan_done=1;
        source_frame(1);wait(pub);read_frame(0);wait(player.state==2);
        @(negedge sc);next_key=1;@(negedge sc);next_key=0;
        source_frame(2);wait(pub);read_frame(12);if(pack) $fatal(1,"early wipe release");
        read_frame(24);read_frame(36);read_frame(48);wait(player.state==2);
        if(writes!=2*N) $fatal(1,"ingest frame lengths");
        $display("PASS ingest: scaler/player/real FIFOs/memory, two sizes and orientations, exact writes and four-frame publication");$finish;
    end
    initial begin #3000000;$fatal(1,"ingest timeout player=%d scaler=%d writes=%d",player.state,scaler.state,writes);end
endmodule
