`timescale 1ns/1ps
module tb_enhanced_overlay;
    reg clk=0,rst=1,vs=0,de=0;
    always #5 clk=~clk;
    wire ovs,ode,fs;wire [23:0] rgb;wire [15:0] active;
    integer x,y,n=0,phase=0,fd,selection,gold_pixels;
    reg [15:0] settings=16'h0588;
    reg [2:0] volume=3;
    video_overlay #(.ENHANCED(1),.CLK_HZ(100000)) dut(.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.image_valid(1'b1),
        .i_rgb(24'h4080c0),.settings(settings),.error_code(4'd0),.image_index(2'd1),.media_valid(1'b1),.auto_enabled(1'b1),
        .spectrum_bar(8'd0),.spectrum_valid(1'b0),.diagnostics(109'd0),.fade_gain(5'd16),.volume(volume),.transition_kind(2'd2),
        .o_vs(ovs),.o_de(ode),.o_rgb(rgb),.frame_start(fs),.active_settings(active),.vis_bin());
    always @(negedge clk) if(!rst && ode) begin
        if(phase==0 || phase==6) $fwrite(fd,"%02x%02x%02x\n",rgb[23:16],rgb[15:8],rgb[7:0]);
        if(n==12*640+12 && rgb!==24'h2c5078) $fatal(1,"half-transparent panel blend/alignment");
        if(n==16*640+16 && rgb!==24'hffffff) $fatal(1,"white text dimmed by alpha");
        if(n==280*640+100 && rgb!==24'h4080c0) $fatal(1,"outside overlay not transparent");
        if(n==300*640+100 && rgb!==24'h2c5078) $fatal(1,"ticker backdrop");
        if(phase==0 && dut.active_volume!==3) $fatal(1,"volume changed mid-frame");
        if(phase>=2) begin
            if(rgb===24'hffcc40) begin
                gold_pixels=gold_pixels+1;
                if(n/640<56 || n/640>=58 || n%640<16+selection*64 || n%640>=80+selection*64)
                    $fatal(1,"menu underline escaped two-row slot: selection=%0d x=%0d y=%0d",selection,n%640,n/640);
            end
            if(n==64*640+16 && rgb!==24'hffffff) $fatal(1,"menu obscured TIME text");
            if(n==64*640+224 && rgb!==24'hffffff) $fatal(1,"menu obscured PIC text");
        end
        n=n+1;
    end
    task draw;
        begin
            @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(4) @(negedge clk);n=0;gold_pixels=0;
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin @(negedge clk);de=1;if(y==100) volume=1;end
                @(negedge clk);de=0;repeat(4) @(negedge clk);
            end
            repeat(4) @(negedge clk);if(n!=307200) $fatal(1,"pixel count");
            if(phase>=2 && gold_pixels!=128) $fatal(1,"menu underline area: %0d",gold_pixels);
        end
    endtask
    initial begin
        fd=$fopen("enhanced_frame.hex","w");
        repeat(4) @(negedge clk);rst=0;draw();$fclose(fd);
        if(dut.time_digits!=0 || dut.sec_one<3) $fatal(1,"runtime/frame snapshot");
        phase=1;draw();
        if(dut.active_volume!=1 || dut.time_digits==0 || dut.scroll!=1) $fatal(1,"frame adoption or scrolling");
        for(selection=0;selection<8;selection=selection+1) begin
            phase=selection+2;settings=16'h8588 | (selection<<12);
            if(phase==6) fd=$fopen("enhanced_menu_frame.hex","w");
            draw();
            if(phase==6) $fclose(fd);
        end
        $display("PASS enhanced_overlay: all eight two-pixel underlines, third-row text preserved; full raster, half-alpha pixels, identity outside OSD, white text, frame-stable volume/time and scrolling");$finish;
    end
    initial begin #40000000;$fatal(1,"enhanced overlay timeout");end
endmodule
