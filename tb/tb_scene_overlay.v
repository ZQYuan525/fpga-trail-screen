`timescale 1ns/1ps
// Scene OSD: plate blends, dithered bottom shade ramp, caption/pill/card/menu/fault
// states, level-exact anti-aliased digits against the generated font, pixel-exact
// caption title with its shadow, pixel-exact logo and grass band against the
// generated art, grass growth and slow fall,
// waveform, overview hiding, fade/black background and frame-stable settings.
// +dump=<prefix> writes each checked frame as <prefix>_<phase>.ppm;
// +bg=<file.hex> drives a 640x480 RGB image instead of the flat 0x4080c0.
module tb_scene_overlay;
    reg clk=0,rst=1,vs=0,de=0,image_valid=1,media_valid=0,auto_enabled=1,overview=0,wave_valid=0;
    always #5 clk=~clk;
    reg [15:0] settings=16'h05c8;
    reg [3:0] error_code=0;
    reg [1:0] image_index=0,visualization=1,focus=0;
    reg [2:0] image_total=4,volume=4;
    reg [4:0] fade_gain=16;
    reg [108:0] diag=0;
    reg [32:0] info=0;
    reg [7:0] bar_level=80,wave_level=0,bar_q=0,wave_q=0;
    reg use_bg;integer px,py;
    reg [23:0] background[0:307199];
    wire [23:0] src=use_bg?background[py*640+px]:24'h4080c0;
    wire ovs,ode,fs;wire [23:0] rgb;wire [15:0] active;wire [4:0] bin;
    scene_overlay #(.CLK_HZ(100000)) dut(.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.image_valid(image_valid),.i_rgb(src),
        .settings(settings),.error_code(error_code),.image_index(image_index),.media_valid(media_valid),.auto_enabled(auto_enabled),
        .image_total(image_total),.spectrum_bar(bar_q),.spectrum_valid(1'b1),.diagnostics(diag),.fade_gain(fade_gain),
        .volume(volume),.transition_kind(2'd0),.visualization(visualization),.focus(focus),.overview(overview),
        .wave_bar(wave_q),.wave_peak(8'd128),.wave_valid(wave_valid),.wav_misses(16'h0123),.wav_minimum(10'd128),
        .media_info(info),.o_vs(ovs),.o_de(ode),.o_rgb(rgb),.frame_start(fs),.active_settings(active),.vis_bin(bin));
    // Spectrum/waveform RAMs answer vis_bin one clock later; bin 5 is silent.
    always @(posedge clk) begin bar_q<=bin==5?8'd0:bar_level;wave_q<=wave_level;end
    reg [23:0] frame[0:307199];
    reg [15:0] font_lo[0:4095],font_hi[0:2047],title_mem[0:4095],logo_mem[0:2047],grass_mem[0:6143];
    reg [8*200-1:0] dump_prefix;reg dumping;
    integer n,phase,fd,i,j,count;
    always @(negedge clk) if(!rst && ode) begin frame[n]=rgb;n=n+1;end
    task draw;
        begin
            @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(300) @(negedge clk);n=0;
            for(py=0;py<480;py=py+1) begin
                for(px=0;px<640;px=px+1) begin de=1;@(negedge clk);end
                de=0;repeat(6) @(negedge clk);
            end
            repeat(8) @(negedge clk);
            if(n!=307200) $fatal(1,"FAIL phase %0d pixel count %0d",phase,n);
            if(dumping) begin
                fd=$fopen($sformatf("%0s_%0d.ppm",dump_prefix,phase),"wb");
                $fwrite(fd,"P6\n640 480\n255\n");
                for(i=0;i<307200;i=i+1) $fwrite(fd,"%c%c%c",frame[i][23:16],frame[i][15:8],frame[i][7:0]);
                $fclose(fd);
            end
        end
    endtask
    function [23:0] at(input integer xx,input integer yy);
        at=frame[yy*640+xx];
    endfunction
    task check_px(input integer xx,input integer yy,input [23:0] value,input [8*40-1:0] what);
        if(at(xx,yy)!==value) $fatal(1,"FAIL phase %0d %0s at (%0d,%0d): %h expected %h",phase,what,xx,yy,at(xx,yy),value);
    endtask
    // Text coverage: level 1 = 3/4 picture + 1/4 ink, 2 = half each, 3 = ink (shift blends).
    function [23:0] aa(input [23:0] rgb,input [23:0] ink,input [1:0] lvl);
        reg [23:0] hr,hi;
        begin
            hr={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]};hi={1'b0,ink[23:17],1'b0,ink[15:9],1'b0,ink[7:1]};
            case(lvl)
                1:aa=hr+{1'b0,hr[23:17],1'b0,hr[15:9],1'b0,hr[7:1]}+{1'b0,hi[23:17],1'b0,hi[15:9],1'b0,hi[7:1]};
                2:aa=hr+hi;3:aa=ink;default:aa=rgb;
            endcase
        end
    endfunction
    // An 8x16 half-width glyph cell on a glass plate must equal the generated font level
    // by level: full = ink, partial = exact blend over the plate, none = plate. Over a real
    // background only full coverage is exact and empty pixels must not be ink.
    task expect_glyph(input integer x0,input integer y0,input [7:0] code,input [23:0] ink,input [8*40-1:0] what);
        reg [15:0] word;reg [1:0] lvl;
        begin
            for(j=0;j<16;j=j+1) begin
                word=code[7]?font_hi[code[6:0]*32+j*2]:font_lo[code[6:0]*32+j*2];
                for(i=0;i<8;i=i+1) begin
                    lvl=word>>(2*i);
                    if(!use_bg ? at(x0+i,y0+j)!==aa(24'h254968,ink,lvl) : (lvl==3 && at(x0+i,y0+j)!==ink) || (lvl==0 && at(x0+i,y0+j)===ink))
                        $fatal(1,"FAIL phase %0d %0s glyph %0d level %0d pixel (%0d,%0d) = %h",phase,what,code,lvl,i,j,at(x0+i,y0+j));
                end
            end
        end
    endtask
    function [1:0] title_level(input integer xx,input integer yy);
        title_level=(xx<32 || xx>=288 || yy<357 || yy>=381)?2'd0:title_mem[image_index*768+(yy-357)*32+(xx-32)/8]>>(2*((xx-32)%8));
    endfunction
    function integer ink_count(input integer x0,input integer y0,input integer w,input integer h,input [23:0] ink);
        integer a,b;
        begin
            ink_count=0;
            for(b=y0;b<y0+h;b=b+1) for(a=x0;a<x0+w;a=a+1) if(at(a,b)===ink) ink_count=ink_count+1;
        end
    endfunction
    localparam [23:0] BG=24'h4080c0,WHITE=24'hffffff,GREEN=24'h78e6a0,GOLD=24'hffcc40,BODY=24'hd7e6de,ALERT=24'hff9682,
        PLATE=24'hd0e0f0,NAVY=24'h061a3d,RED=24'hc70614;
    // Flat background after the bottom shade: (16-s)/16 with
    // s = ((y-224)/2 + bayer(x,y))/16 from y=224, bayer = 4x4 ordered dither 0..15.
    function [23:0] shaded(input integer xx,input integer yy);
        integer s,g,bayer;reg [7:0] r8,g8,b8;
        begin
            bayer=(((xx^yy)&1)<<3)|((yy&1)<<2)|((((xx^yy)>>1)&1)<<1)|((yy>>1)&1);
            s=yy<224?0:((yy-224)/2+bayer)/16;g=16-s;
            r8=64*g/16;g8=128*g/16;b8=192*g/16;shaded={r8,g8,b8};
        end
    endfunction
    function [23:0] quarter(input [23:0] c);
        quarter={2'b0,c[23:18],2'b0,c[15:10],2'b0,c[7:2]};
    endfunction
    function [23:0] grass_tone(input integer tone);
        case(tone) 0:grass_tone=24'h122016;1:grass_tone=24'h28422a;2:grass_tone=24'h4e7042;3:grass_tone=24'h84a260;default:grass_tone=24'hc4cc80; endcase
    endfunction
    function is_grass(input [23:0] c);
        is_grass=c===24'h122016 || c===24'h28422a || c===24'h4e7042 || c===24'h84a260 || c===24'hc4cc80;
    endfunction
    function is_ink(input [23:0] c);
        is_ink=c===WHITE || c===BODY;
    endfunction
    integer q,g,tone,shadows,blades,partial;reg [23:0] under;
    initial begin
        use_bg=$value$plusargs("bg=%s",dump_prefix);
        if(use_bg) $readmemh(dump_prefix,background);
        dumping=$value$plusargs("dump=%s",dump_prefix);
        $readmemh("scene_font_lo.hex",font_lo);$readmemh("scene_font_hi.hex",font_hi);$readmemh("scene_title.hex",title_mem);
        $readmemh("scene_logo.hex",logo_mem);$readmemh("scene_grass.hex",grass_mem);
        repeat(4) @(negedge clk);rst=0;
        // LOAD freezes at 01.93 s (CLK_HZ=1e5: 1000 cycles per centisecond).
        wait(dut.load_centis==193);media_valid=1;
        info={12'd40,10'd960,11'd1280};
        phase=0;draw();draw();draw();
        if(!use_bg) begin
            check_px(320,200,BG,"unshaded image");
            check_px(320,223,BG,"shade starts at 224");
            check_px(320,280,24'h3c78b4,"bottom shade ramp, dither 0");
            check_px(341,281,24'h3870a8,"bottom shade ramp, dither 4 (neighbour one level darker)");
            check_px(340,360,24'h306090,"bottom shade ramp at caption");
            check_px(100,12,24'h254968,"pill glass");
            check_px(12,10,BG,"pill rounded corner");
            check_px(300,60,24'h254968,"maintenance card glass");
            check_px(300,352,shaded(300,352),"caption has no plate");
            check_px(433,30,PLATE,"logo plate");
            check_px(430,8,BG,"logo plate rounded corner");
            check_px(320,446,24'h0c1b22,"subtitle band over shade");
            check_px(320,444,GREEN,"subtitle band rule");
            // Caption title rows above the grass, pixel-exact: anti-aliased white over the shaded
            // image, with a shadow (a quarter of the image) one pixel down-right of every
            // half-or-more covered title pixel.
            shadows=0;partial=0;
            for(j=357;j<372;j=j+1) for(i=28;i<300;i=i+1) begin
                under=j>357 && title_level(i-1,j-1)>=2?quarter(shaded(i,j)):shaded(i,j);
                if(under!==shaded(i,j) && title_level(i,j)==0) shadows=shadows+1;
                if(title_level(i,j)==1 || title_level(i,j)==2) partial=partial+1;
                check_px(i,j,aa(under,WHITE,title_level(i,j)),"caption title / shadow");
            end
            if(shadows<60 || partial<60) $fatal(1,"FAIL caption shadow %0d / anti-aliased edge %0d pixels",shadows,partial);
        end
        check_px(17,380,GREEN,"caption accent");
        check_px(13,60,GREEN,"card accent");
        check_px(26,22,GREEN,"pill dot");
        // Logo pixel-exact against make_scene_art.py: 192x48 at (436,12).
        for(j=0;j<48;j=j+1) for(i=0;i<192;i=i+1) begin
            q=(logo_mem[j*32+i/8]>>(2*(i%8)))&3;
            if(q==1) check_px(436+i,12+j,NAVY,"logo navy");
            else if(q==2) check_px(436+i,12+j,RED,"logo red");
            else if(!use_bg) check_px(436+i,12+j,PLATE,"logo plate inside");
        end
        if(ink_count(436,12,192,48,NAVY)<1500 || ink_count(436,12,192,48,RED)<200) $fatal(1,"FAIL logo navy/red count");
        // Digits: pill page 1/4; LOAD 01.93 and INIT 00.40 on maintenance line 1.
        expect_glyph(110,15,2,WHITE,"page number");expect_glyph(118,15,19,WHITE,"page slash");expect_glyph(126,15,5,WHITE,"page total");
        expect_glyph(64,68,0,WHITE,"load leading blank");expect_glyph(72,68,2,WHITE,"load ones");expect_glyph(80,68,17,WHITE,"load dot");
        expect_glyph(88,68,10,WHITE,"load tenths");expect_glyph(96,68,4,WHITE,"load hundredths");
        expect_glyph(192,68,0,WHITE,"init leading blank");expect_glyph(200,68,1,WHITE,"init ones");
        expect_glyph(216,68,5,WHITE,"init tenths");expect_glyph(224,68,1,WHITE,"init hundredths");
        if(ink_count(24,48,64,16,GREEN)<40) $fatal(1,"FAIL maintenance title colour");
        if(ink_count(32,357,256,24,WHITE)<200) $fatal(1,"FAIL caption title");
        if(ink_count(32,394,288,16,BODY)<200) $fatal(1,"FAIL caption body");
        if(ink_count(0,450,640,20,WHITE)<600) $fatal(1,"FAIL subtitle text");
        if(ink_count(340,140,120,190,WHITE)!=0) $fatal(1,"FAIL stray text in the picture");
        // Grass: bins 0..9 on x>=320, 10..19 below; bar 80 grows every bin to level 15,
        // silent bin 5 (x 480..511) stays at 5, and under the caption (x<344) the level
        // is held at 6. Pixel-exact against make_scene_art.py outside the caption text,
        // accent and shadow.
        if(dut.grow[2]!==15 || dut.grow[12]!==15 || dut.grow[5]!==5) $fatal(1,"FAIL grass levels %0d %0d %0d",dut.grow[2],dut.grow[12],dut.grow[5]);
        blades=0;
        for(j=372;j<444;j=j+1) for(i=0;i<640;i=i+1) if(!((i<360 && j<412) || (i>=16 && i<20 && j<420))) begin
            q=(grass_mem[(j-372)*80+(i%320)/4]>>(4*(i%4)))&15;
            g=(i>=320 && (i-320)/32==5)?5:15;if(i<344 && g>6) g=6;
            if(q<g) begin
                tone=q/4+((g>=12 && q+4>=g)?1:0);
                check_px(i,j,grass_tone(tone),"grass");blades=blades+1;
            end else if(!use_bg) check_px(i,j,shaded(i,j),"no grass");
        end
        if(blades<2500) $fatal(1,"FAIL grass pixel count %0d",blades);
        check_px(304,342,GREEN,"current page dot");
        check_px(315,342,24'hc8d2cd,"other page dot");
        // Grass falls one level every fourth frame once the spectrum drops.
        bar_level=0;phase=6;draw();draw();
        if(dut.grow[2]<14) $fatal(1,"FAIL grass dropped at once: %0d",dut.grow[2]);
        repeat(8) draw();
        if(dut.grow[2]<12 || dut.grow[2]>13) $fatal(1,"FAIL grass fall rate: %0d after 10 frames",dut.grow[2]);
        // Menu: selection 2 (运维信息) is gold with a marker, other lines white.
        settings=16'ha5c8;phase=1;draw();draw();
        if(ink_count(24,108,96,16,GOLD)<60) $fatal(1,"FAIL selected menu line colour");
        if(ink_count(24,68,96,16,WHITE)<40) $fatal(1,"FAIL unselected menu line");
        check_px(18,116,GOLD,"menu selection marker");
        if(!use_bg) check_px(250,220,24'h254968,"menu card extent");
        // Overview: no logo, caption or shade; browse pill and hint.
        settings=16'h05c8;overview=1;focus=2;phase=2;draw();draw();
        if(!use_bg) begin check_px(433,30,BG,"overview hides logo");check_px(300,352,BG,"overview hides caption");end
        if(ink_count(0,372,640,72,24'h122016)!=0) $fatal(1,"FAIL overview hides grass");
        expect_glyph(110,15,4,WHITE,"overview focus number");
        // Fault F with a captured report: red pill, diagnostics card.
        overview=0;error_code=4'hf;diag[108]=1;diag[95:92]=4'h2;phase=3;draw();draw();
        if(!use_bg) begin check_px(100,12,24'h604a6a,"fault pill red glass");check_px(300,140,24'h254968,"diagnostics card extent");end
        check_px(26,22,24'hff5a50,"fault dot");
        check_px(13,60,ALERT,"diagnostics accent");
        expect_glyph(80,68,3,WHITE,"init status digit");
        // Waveform mode, SW2-hidden card, fade and unpublished image.
        error_code=0;diag=0;visualization=2;wave_valid=1;settings=16'h0548;fade_gain=8;phase=4;draw();draw();
        check_px(400,396,24'h20ff90,"waveform centre");
        check_px(622,400,24'hffb020,"wave peak meter");
        check_px(400,427,24'h96aaa0,"waveform baseline");
        for(j=372;j<444;j=j+1) for(i=360;i<640;i=i+1) if(is_grass(at(i,j))) $fatal(1,"FAIL grass in waveform mode at (%0d,%0d)",i,j);
        if(!use_bg) begin check_px(300,60,24'h204060,"card hidden, fade halves the image");check_px(320,200,24'h204060,"fade");end
        image_valid=0;fade_gain=16;phase=5;draw();draw();
        check_px(320,200,24'h000000,"unpublished image is black");
        if(ink_count(24,15,96,16,WHITE)<40) $fatal(1,"FAIL pill text over black");
        // Settings are adopted only at a frame start.
        @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(300) @(negedge clk);
        settings=16'h0000;repeat(20) @(negedge clk);
        if(active!==16'h0548) $fatal(1,"FAIL settings changed mid-frame %h",active);
        $display("PASS scene_overlay: plates/dithered shade ramp/band blends, pill/card/caption/menu/fault/overview states, level-exact anti-aliased page/LOAD/INIT digits, pixel-exact title with shadow, pixel-exact logo and grass, grass growth/caption hold/slow fall, waveform, fade, black image, frame-stable settings");
        $finish;
    end
    initial begin #400_000_000;$fatal(1,"FAIL scene_overlay timeout");end
endmodule
