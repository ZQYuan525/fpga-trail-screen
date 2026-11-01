`timescale 1ns/1ps
module tb_advanced_overlay;
    reg clk=0,rst=1,vs=0,de=0,overview=0;
    reg [1:0] viz=2;
    reg [15:0] settings=16'h85c8;
    always #5 clk=~clk;
    wire ovs,ode,fs;wire [23:0] rgb;wire [15:0] active;
    integer x,y,n=0,phase=0,fd;
    // One-clock bin read ports, as audio_spectrum/audio_waveform.
    localparam [255:0] SPECTRUM={32{8'd64}},WAVE={4{64'hc080c000407f4000}};
    wire [4:0] vis_bin;reg [7:0] spectrum_bar=0,wave_bar=0;
    always @(posedge clk) begin spectrum_bar<=SPECTRUM[vis_bin*8 +: 8];wave_bar<=WAVE[vis_bin*8 +: 8];end
    video_overlay #(.ADVANCED(1),.ENHANCED(1)) dut(.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.image_valid(1'b1),.i_rgb(24'h4080c0),
        .settings(settings),.error_code(4'd0),.image_index(2'd1),.media_valid(1'b1),.auto_enabled(1'b1),
        .spectrum_bar(spectrum_bar),.spectrum_valid(1'b1),.diagnostics(109'd0),.fade_gain(5'd16),.volume(3'd4),.transition_kind(2'd0),
        .visualization(viz),.focus(2'd2),.overview(overview),.wave_bar(wave_bar),.wave_peak(8'd64),.wave_valid(1'b1),
        .wav_misses(16'h0123),.wav_minimum(10'd128),.o_vs(ovs),.o_de(ode),.o_rgb(rgb),.frame_start(fs),.active_settings(active),.vis_bin(vis_bin));
    always @(negedge clk) if(!rst && ode) begin
        if(phase==0) $fwrite(fd,"%06x\n",rgb);
        // Logo pixels picked from tb/logo_rom.hex; plate = 3/4 white over 4080c0.
        if(n==150*640+532 && rgb!==(phase==1?24'h4080c0:24'h122041)) $fatal(1,"logo navy / overview hide");
        if(n==144*640+493 && rgb!==(phase==1?24'h4080c0:24'hcd1220)) $fatal(1,"logo red");
        if(n==140*640+472 && rgb!==(phase==1?24'h4080c0:24'hd0e0f0)) $fatal(1,"logo plate");
        if(n==137*640+469 && rgb!==(phase==1?24'h4080c0:24'hd0e0f0)) $fatal(1,"logo plate margin");
        if(n==137*640+467 && rgb!==24'h4080c0) $fatal(1,"logo plate extent");
        if(phase==3) begin
            // 64-high bars span rows 384-447: bottom green, then three warmer bands.
            if(n==440*640+68 && rgb!==24'h40e0a0) $fatal(1,"spectrum gradient bottom");
            if(n==410*640+68 && rgb!==24'h90e050) $fatal(1,"spectrum gradient lower");
            if(n==390*640+68 && rgb!==24'he0d040) $fatal(1,"spectrum gradient upper");
            if(n==383*640+68 && rgb!==24'h4080c0) $fatal(1,"spectrum bar height");
            if(n==440*640+78 && rgb!==24'h4080c0) $fatal(1,"spectrum bar gap");
        end else begin
        if(n==280*640+100 && rgb!==24'h4080c0) $fatal(1,"overlay background");
        if(n==369*640+100 && rgb!==(phase==0?24'h20ff90:24'h4080c0)) $fatal(1,"wave mode/frame stability");
        if(n==432*640+164 && phase!=1 && rgb!==(phase==0?24'h20ff90:24'h4080c0)) $fatal(1,"negative full-scale wave");
        if(n==384*640+84 && rgb!==(phase==0?24'h20ff90:24'h4080c0)) $fatal(1,"positive wave amplitude");
        if(n==416*640+148 && phase!=1 && rgb!==(phase==0?24'h20ff90:24'h4080c0)) $fatal(1,"negative wave amplitude");
        if(n==420*640+590 && phase!=1 && rgb!==(phase==0?24'hffb020:24'h4080c0)) $fatal(1,"peak mode");
        if(n==300*640+100 && rgb!==(phase==1?24'h4080c0:24'h2c5078)) $fatal(1,"ticker overlaid thumbnail");
        if(n==88*640+24 && rgb!==24'hffcc40) $fatal(1,"B/C parameter bar");
        if(n==88*640+88 && rgb!==24'h304050) $fatal(1,"B/C bar level");
        end
        n=n+1;
    end
    task draw;begin
        @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(4) @(negedge clk);n=0;
        for(y=0;y<480;y=y+1) begin
            for(x=0;x<640;x=x+1) begin @(negedge clk);de=1;if(phase==0 && y==100) viz=0;end
            @(negedge clk);de=0;repeat(4) @(negedge clk);
        end
        repeat(4) @(negedge clk);if(n!=307200) $fatal(1,"overlay pixel alignment");
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        fd=$fopen("waveform_frame.hex","w");draw();$fclose(fd);
        overview=1;phase=1;viz=2;draw();
        overview=0;phase=2;viz=0;draw();
        phase=3;viz=1;draw();
        if(dut.misses_q!=16'h0123 || dut.minimum_q!=128) $fatal(1,"audio telemetry snapshot");
        $display("PASS advanced_overlay: wave/peak pixel output, spectrum gradient, logo, frame-stable mode, overview layout, parameter bar, audio telemetry, RGB/DE alignment");$finish;
    end
    initial begin #15000000;$fatal(1,"advanced overlay timeout");end
endmodule
