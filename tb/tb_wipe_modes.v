`timescale 1ns/1ps
module tb_wipe_modes;
    reg [1:0] kind=0;
    integer mode,lo,hi;
    reg memclk=0,pclk=0,rst=1,req=0,pub=0,ren=0;
    always #10 memclk=~memclk;always #20 pclk=~pclk;
    reg [1:0] bufidx=0;reg fade=0;
    reg [1:0] image=2;wire [1:0] displayed_image;
    wire ack,pack,display_valid,finish,rd_busy,cmd,rv,error,underflow;
    wire [20:0] addr;wire [31:0] data;
    reg ret=0;reg [31:0] retdata=0;
    integer n,frames=0,commands=0;
    sdram_read_ctrl #(.ENHANCED_WIPE(1),.BURST_SIZE(8),.WIPE_FRAMES(4),.MANUAL_FADE(1)) dut(
        .mem_clk(memclk),.clk_video(pclk),.rst(rst),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.wr_busy(1'b0),
        .rd_busy(rd_busy),.read_req(req),.read_req_ack(ack),.read_finish(finish),.publish_req(pub),.publish_buf(bufidx),
        .publish_image(image),.display_image(displayed_image),.publish_fade(fade),.wipe_kind(kind),
        .publish_ack(pack),.display_valid(display_valid),.read_addr0(21'd0),.read_addr1(21'd64),.read_addr2(21'd0),.read_addr3(21'd0),.read_len(21'd24),
        .Sdr_rd_en(ret),.Sdr_rd_dout(retdata),.App_rd_en(cmd),.App_rd_addr(addr),.read_en(ren),.read_data(data),.read_valid(rv),.memory_error(error),.underflow(underflow));
    always @(posedge memclk) begin
        ret<=!rst && cmd;
        if(cmd) begin retdata<=32'had000000+addr;commands=commands+1;end
    end
    task frame(input integer boundary,expect_ack);
        begin
            lo=boundary==0?0:kind==0?0:kind==1?24-boundary:12-boundary/2;
            hi=boundary==0?0:kind==0?boundary:kind==1?24:12+boundary/2;
            @(negedge pclk);req=1;wait(ack);@(negedge pclk);req=0;wait(!ack);wait(finish);
            if(pack!=expect_ack) $fatal(1,"premature/missing old-buffer release frame=%0d",frames);
            if(displayed_image!=(boundary==24?3:2)) $fatal(1,"image metadata changed before complete wipe");
            for(n=0;n<24;n=n+1) begin
                @(negedge pclk);ren=1;@(negedge pclk);ren=0;
                if(!rv || data!==32'had000000+n+((n>=lo && n<hi)?64:0)) $fatal(1,"wipe frame=%0d pixel=%0d value=%h",frames,n,data);
            end
            frames=frames+1;
            if(error || underflow || commands!=frames*24) $fatal(1,"wipe flow error/count");
        end
    endtask
    initial begin
        for(mode=0;mode<3;mode=mode+1) begin
            rst=1;req=0;pub=0;ren=0;bufidx=0;image=2;fade=0;frames=0;commands=0;kind=mode;
            repeat(8) @(negedge pclk);rst=0;pub=1;frame(0,1);pub=0;repeat(10) @(negedge pclk);
            bufidx=1;image=3;pub=1;frame(6,0);frame(12,0);frame(18,0);frame(24,1);
            pub=0;repeat(10) @(negedge pclk);frame(24,0);
        end
        $display("PASS wipe_modes: every pixel source checked for top-down, bottom-up and center-out; frame-boundary ownership retained");$finish;
    end
    initial begin #1000000;$fatal(1,"transition timeout");end
endmodule
