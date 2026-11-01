`timescale 1ns/1ps
module tb_overlay;
    reg clk=0,rst=1,vs=0,de=0,image_valid=1;always #5 clk=~clk;
    reg [23:0] rgb=24'h2080e0;
    reg [15:0] settings=16'h0500;
    reg [108:0] diagnostics=0;
    reg [4:0] gain=16;
    wire ovs,ode,fs;wire [23:0] output_rgb;wire [15:0] active;
    integer x,y,received=0,phase=0;
    reg [23:0] expected;
    reg [8*18-1:0] diag_line1="I:0 B:3 N:4 F:E608";
    reg [8*17-1:0] diag_line2="L:0000070A H:4D42";
    reg [8*14-1:0] diag_line3="P:00080 R:3-FF";
    always @(negedge clk) if(!rst && phase==5 && dut.s_de && dut.sx>=16 && dut.tx[3:0]==0) begin
        if(dut.sy==64 && dut.column<18 && dut.character!==diag_line1[(17-dut.column)*8 +: 8])
            $fatal(1,"diagnostics first row field mapping at column %0d",dut.column);
        if(dut.sy==88 && dut.column<17 && dut.character!==diag_line2[(16-dut.column)*8 +: 8])
            $fatal(1,"diagnostics LBA/signature mapping at column %0d",dut.column);
        if(dut.sy==112 && dut.column<14 && dut.character!==diag_line3[(13-dut.column)*8 +: 8])
            $fatal(1,"diagnostics pixel count mapping at column %0d",dut.column);
    end
    video_overlay #(.WIDTH(480),.HEIGHT(144),.DIAGNOSTICS(1),.FADE(1)) dut(.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.i_rgb(rgb),
        .diagnostics(diagnostics),.fade_gain(gain),
        .image_valid(image_valid),.image_index(2'd2),.media_valid(1'b1),.auto_enabled(1'b1),
        .settings(settings),.error_code(4'd0),.spectrum_bar(8'd0),.spectrum_valid(1'b0),
        .o_vs(ovs),.o_de(ode),.o_rgb(output_rgb),.frame_start(fs),.active_settings(active),.vis_bin());
    always @(negedge clk) if(!rst && ode) begin
        if(phase==0 && output_rgb!==24'h2080e0) $fatal(1,"neutral color/alignment or midframe settings");
        if(phase==1 && output_rgb!==24'h00a0ff) $fatal(1,"contrast/brightness saturation: %h",output_rgb);
        if(phase==3 && output_rgb!==0) $fatal(1,"unpublished/fault background must remain black");
        if(phase==6 && output_rgb!==0) $fatal(1,"brightness/contrast lifted fade black");
        if(phase==7 && received/480==16 && received%480==16 && output_rgb!==24'hffffff) $fatal(1,"fade dimmed OSD");
        if(phase==7 && received/480==0 && output_rgb!==0) $fatal(1,"fade black background with OSD");
        if(phase==8 && output_rgb!==24'h00507f) $fatal(1,"fade must scale adjusted RGB, got %h",output_rgb);
        // F top row is all five white pixels, followed by background.
        if(phase==2 && received/480==16 && received%480==16 && output_rgb!==24'hffffff) $fatal(1,"font row/bit order");
        if(phase==2 && received/480==16 && received%480==26 && output_rgb!==24'h182030) $fatal(1,"font spacing/background");
        if(phase==2 && received/480==16 && received%480==336 && output_rgb!==24'hffffff) $fatal(1,"PIC number glyph");
        if(phase==2 && received/480==16 && received%480==468 && output_rgb!==24'hffffff) $fatal(1,"AUTO status glyph");
        if(phase==4 && received/480==56 && received%480==336 && output_rgb!==24'hffcc40) $fatal(1,"sixth menu underline");
        if(phase==4 && received/480==40 && received%480==308 && output_rgb!==24'hffffff) $fatal(1,"period ten digit");
        if(phase==4 && received/480==40 && received%480==368 && output_rgb!==24'hffffff) $fatal(1,"media source M glyph");
        if(phase==5 && received/480==64 && received%480==18 && output_rgb!==24'hffffff) $fatal(1,"diagnostics I glyph");
        if(phase==5 && received/480==88 && received%480==16 && output_rgb!==24'hffffff) $fatal(1,"diagnostics L glyph");
        if(phase==5 && received/480==112 && received%480==16 && output_rgb!==24'hffffff) $fatal(1,"diagnostics P glyph/frame stability");
        received=received+1;
    end
    task draw;
        begin
            @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(4) @(negedge clk);
            received=0;
            for(y=0;y<144;y=y+1) begin
                for(x=0;x<480;x=x+1) begin
                    @(negedge clk);de=1;
                    if(phase==0 && y==20 && x==20) settings=16'h0a00;
                    if(phase==5 && y==80 && x==20) diagnostics=0;
                end
                @(negedge clk);de=0;repeat(4) @(negedge clk);
            end
            repeat(4) @(negedge clk);
            if(received!=480*144) $fatal(1,"overlay lost pixels %0d",received);
        end
    endtask
    initial begin
        #23;rst=0;draw();phase=1;draw();phase=2;settings=16'h0580;draw();
        phase=3;image_valid=0;settings=16'h0a00;draw();
        phase=4;image_valid=1;settings=16'hd5b8;draw();
        phase=5;settings=16'h0500;
        diagnostics={1'b1,12'h3ff,4'd0,4'd3,4'd4,16'he608,32'h70a,16'h4d42,20'h80};draw();
        phase=6;settings=16'h0a00;gain=0;draw();
        phase=7;settings=16'h0a80;draw();
        phase=8;settings=16'h0a00;gain=8;draw();
        $display("PASS overlay: neutral identity, frame-stable settings, saturation, two-stage alignment, font pixels");$finish;
    end
    initial begin #9000000;$fatal(1,"overlay timeout");end
endmodule
