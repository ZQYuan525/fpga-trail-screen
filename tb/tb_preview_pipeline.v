`timescale 1ns/1ps
module tb_preview_pipeline;
    reg sd=0,clk=0,rst=1,load=0,write_pixel=0,vs=0,de=0;
    always #5 sd=~sd;always #20 clk=~clk;
    reg [1:0] slot=0;reg [23:0] wrgb=0;
    wire pvs,pde,view,ovs,ode,frame,user,valid,last;
    wire [23:0] prgb,orgb,data;
    wire overflow;
    thumbnail_preview preview(.sd_clk(sd),.sd_rst(rst),.load_start(load),.abort_load(1'b0),.write_pixel(write_pixel),
        .source_top_down(1'b1),.write_slot(slot),.write_rgb(wrgb),.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.i_rgb(24'h204060),
        .view_mode(1'b1),.confirm_pending(1'b0),.focus(2'd2),.complete(4'b1011),.bad(4'b0100),.catalog(4'b1111),.fade_gain(5'd16),
        .o_vs(pvs),.o_de(pde),.o_rgb(prgb),.active_view(view));
    video_overlay #(.ADVANCED(1),.ENHANCED(1),.FADE(1)) overlay(.clk(clk),.rst(rst),.i_vs(pvs),.i_de(pde),.i_rgb(prgb),.image_valid(1'b1),
        .settings(16'h05c8),.error_code(4'd0),.image_index(2'd0),.media_valid(1'b1),.auto_enabled(1'b0),
        .spectrum_bar(8'd255),.spectrum_valid(1'b1),.diagnostics(109'd0),.fade_gain(5'd16),.volume(3'd4),.transition_kind(2'd0),
        .visualization(2'd1),.focus(2'd2),.overview(view),.wave_bar(8'd0),.wave_peak(8'd64),.wave_valid(1'b1),
        .wav_misses(16'd0),.wav_minimum(10'd128),.o_vs(ovs),.o_de(ode),.o_rgb(orgb),.frame_start(frame),.active_settings(),.vis_bin());
    rgb_to_axis axis(.clk(clk),.rst(rst),.i_vs(ovs),.i_de(ode),.i_rgb(orgb),.i_ready(1'b1),
        .o_user(user),.o_valid(valid),.o_last(last),.o_data(data),.overflow(overflow));
    integer s,x,y,n=0,fd;
    always @(negedge clk) if(!rst && valid) begin
        if(user!==(n==0) || last!==(n%640==639)) $fatal(1,"preview AXIS frame alignment n=%0d",n);
        if(n==170*640+200 && data!==24'hff49aa) $fatal(1,"preview to overlay RGB alignment");
        if(n==350*640+400 && data!==24'h00dbff) $fatal(1,"FFT covered preview");
        if(n==300*640+200 && data!==24'h301818) $fatal(1,"ticker covered bad-slot placeholder");
        if(n==270*640+112 && data!==24'hffcc40) $fatal(1,"focus border lost");
        $fwrite(fd,"%06x\n",data);n=n+1;
    end
    initial begin
        fd=$fopen("preview_pipeline_frame.hex","w");
        repeat(4) @(negedge sd);rst=0;
        for(s=0;s<4;s=s+1) begin
            @(negedge sd);slot=s;wrgb=s==0?24'he04080:s==1?24'h40c040:24'h00c0c0;load=1;
            @(negedge sd);load=0;write_pixel=1;repeat(307200) @(negedge sd);write_pixel=0;
        end
        @(negedge clk);vs=1;repeat(5) @(negedge clk);vs=0;repeat(5) @(negedge clk);
        for(y=0;y<480;y=y+1) begin
            for(x=0;x<640;x=x+1) begin @(negedge clk);de=1;end
            @(negedge clk);de=0;repeat(10) @(negedge clk);
        end
        repeat(10) @(negedge clk);$fclose(fd);
        if(n!=307200 || overflow) $fatal(1,"preview pipeline frame count/overflow");
        $display("PASS preview_pipeline: real capture through preview/OSD/AXIS, frame and line tags, colors, focus, overlay exclusion, full frame");$finish;
    end
    initial begin #50000000;$fatal(1,"preview pipeline timeout");end
endmodule
