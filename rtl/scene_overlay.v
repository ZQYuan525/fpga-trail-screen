`timescale 1ns/1ps
// Scene OSD: Chinese status pill, maintenance / fault / menu card, plate-less
// caption with a one-pixel shadow and page dots, a grass band that grows with the
// spectrum (or the waveform), subtitle band and the logo, over a 16-level bottom
// shade folded into the fade gain. Text comes from scene_text_rom.v
// (maintenance/make_scene_text.py), logo and grass from scene_art_rom.v
// (maintenance/make_scene_art.py); row numbers and slot ids below are the
// contract with those generators.
// Text pixels are 2-bit coverage levels blended over what lies beneath (1/4, 1/2, full).
// Pipeline: x/y addresses every ROM; stage 1 (x1/y1) resolves template slots and
// adjusts the image; stage 2 (x2/y2) composes; o_rgb is registered after it.
module scene_overlay #(
    parameter WIDTH=640,HEIGHT=480,CLK_HZ=25_000_000
)(
    input wire clk,rst,i_vs,i_de,image_valid,input wire [23:0] i_rgb,
    input wire [15:0] settings,input wire [3:0] error_code,
    input wire [1:0] image_index,input wire media_valid,auto_enabled,
    input wire [2:0] image_total,
    input wire [7:0] spectrum_bar,input wire spectrum_valid,
    input wire [108:0] diagnostics,
    input wire [4:0] fade_gain,
    input wire [2:0] volume,input wire [1:0] transition_kind,
    input wire [1:0] visualization,focus,input wire overview,
    input wire [7:0] wave_bar,input wire [7:0] wave_peak,input wire wave_valid,
    input wire [15:0] wav_misses,input wire [9:0] wav_minimum,
    input wire [32:0] media_info, // {SD init time in centiseconds, displayed BMP height, width}
    output reg o_vs,o_de,output reg [23:0] o_rgb,
    output wire frame_start,output reg [15:0] active_settings,
    output wire [4:0] vis_bin // spectrum_bar/wave_bar return this bin one clock later
);
    localparam integer CELLS=40;
    localparam [9:0] LOGO_X=436,LOGO_Y=12,SPEC_X=360,SPEC_BASE=426,GRASS_Y=372,GRASS_H=72;
    localparam [23:0] WHITE=24'hffffff,GREEN=24'h78e6a0,GOLD=24'hffcc40,BODY=24'hd7e6de,
        ALERT=24'hff9682,RED_DOT=24'hff5a50,DOT=24'hc8d2cd,BASELINE=24'h96aaa0,
        WAVE=24'h20ff90,WAVE_AXIS=24'h406060,PEAK=24'hffb020,
        LOGO_NAVY=24'h061a3d,LOGO_RED=24'hc70614;
    reg vs_d;
    reg [9:0] x,y;
    reg [3:0] card_line,card_grow;
    reg [4:0] card_k,card_off; // y-48 = 20*card_k + card_off once y>=48
    assign frame_start=i_vs && !vs_d;

    // ---- frame-stable state ----
    reg [3:0] active_error;
    reg active_auto,active_overview,active_media,parity;
    reg [2:0] active_volume,active_total;
    reg [1:0] active_transition,active_visualization,active_focus,active_index;
    reg [108:0] active_diagnostics;
    reg [15:0] misses_q;
    reg [9:0] minimum_q,scroll;
    reg [15:0] time_digits;
    reg [24:0] second_ticks;
    reg [3:0] sec_one,sec_ten,min_one,min_ten;
    always @(posedge clk or posedge rst) begin
        if(rst) begin second_ticks<=0;sec_one<=0;sec_ten<=0;min_one<=0;min_ten<=0;end
        else if(second_ticks==CLK_HZ-1) begin
            second_ticks<=0;
            if(sec_one==9) begin
                sec_one<=0;
                if(sec_ten==5) begin
                    sec_ten<=0;
                    if(min_one==9) begin min_one<=0;min_ten<=min_ten==5?0:min_ten+1'b1;end
                    else min_one<=min_one+1'b1;
                end else sec_ten<=sec_ten+1'b1;
            end else sec_one<=sec_one+1'b1;
        end else second_ticks<=second_ticks+1'b1;
    end

    // ---- media info: first-image time, SD init time, BMP size and zoom ----
    localparam integer CENTI=CLK_HZ/100;
    reg [32:0] info_q;
    reg [$clog2(CENTI)-1:0] centi_ticks;
    reg [13:0] load_centis,load_q;
    reg load_shown;
    wire [19:0] width_bcd,height_bcd,zoom_x_bcd,zoom_y_bcd,init_bcd,load_bcd;
    wire size_known=info_q[10:0]!=0 && info_q[20:11]!=0;
    osd_bcd_fields u_fields(.clk(clk),.rst(rst),
        .width(info_q[10:0]),.height(info_q[20:11]),.rate_x5({3'b0,info_q[32:21]}),.load(load_q),
        .width_bcd(width_bcd),.height_bcd(height_bcd),.zoom_x_bcd(zoom_x_bcd),.zoom_y_bcd(zoom_y_bcd),
        .rate_bcd(init_bcd),.load_bcd(load_bcd));
    always @(posedge clk or posedge rst) begin
        if(rst) begin centi_ticks<=0;load_centis<=0;load_shown<=0;end
        else if(!load_shown) begin
            if(media_valid) load_shown<=1;
            else if(centi_ticks==CENTI-1) begin
                centi_ticks<=0;
                if(load_centis!=9999) load_centis<=load_centis+1'b1;
            end else centi_ticks<=centi_ticks+1'b1;
        end
    end

    // ---- layout state for this frame ----
    wire menu=active_settings[15];
    wire diag=active_diagnostics[108] && !menu;
    wire card=menu || diag || active_settings[7];
    wire fault=active_error>=4'ha;
    wire caption=active_media && !active_overview;
    wire [9:0] card_right=menu?10'd264:diag?10'd328:10'd312;
    wire [9:0] card_bottom=menu?10'd228:diag?10'd148:10'd128;
    wire [3:0] card_lines=menu?4'd9:diag?4'd5:4'd4;
    wire [5:0] pill_row=fault?6'd4+{2'b0,active_error-4'ha}:active_overview?6'd2:!active_media?6'd3:active_auto?6'd0:6'd1;
    wire [9:0] pill_right=fault?10'd162:!active_media && !active_overview?10'd114:10'd146;
    reg [5:0] menu_row;
    always @(*) case(card_line-1'b1)
        0:menu_row=6'd20+active_settings[11:10];
        1:menu_row=6'd23+active_settings[9:8];
        2:menu_row=6'd26+active_settings[7];
        3:menu_row=6'd28+active_visualization;
        4:menu_row=6'd31+active_settings[5:4];
        5:menu_row=6'd35+active_settings[3];
        6:menu_row=6'd37;
        default:menu_row=6'd38+active_transition;
    endcase

    // ---- stage 0: ROM addresses from the input pixel position ----
    integer p;
    always @(*) begin
        card_line=y>=48 && card_off<16 && card_k<9?card_k[3:0]:4'd15;
        card_grow=card_off[3:0];
    end
    reg t_on;reg [5:0] t_row;reg [9:0] t_x0;reg [3:0] t_grow;reg [2:0] t_color;reg t_sel;
    always @(*) begin
        t_on=0;t_row=0;t_x0=24;t_grow=0;t_color=0;t_sel=0;
        if(y>=15 && y<31) begin t_on=1;t_row=pill_row;t_x0=38;t_grow=y-15;end
        else if(card && card_line<card_lines) begin
            t_on=1;t_grow=card_grow;
            t_row=menu?(card_line==0?6'd19:menu_row):diag?6'd14+card_line:6'd10+card_line;
            t_color=card_line==0?(diag?3'd2:3'd1):0;
            t_sel=menu && card_line!=0 && card_line-1'b1==active_settings[14:12];
            if(t_sel) t_color=3'd3;
        end else if(caption && y>=394 && y<410) begin t_on=1;t_row=6'd41+active_index;t_x0=32;t_grow=y-394;t_color=3'd4;end
    end
    wire [9:0] t_dx=x-t_x0;
    wire t_inside=t_on && x>=t_x0 && t_dx<CELLS*8;
    wire [15:0] template_word,title_word,ticker_word,logo_word,font_lo_word,font_hi_word;
    scene_template_rom u_template(.clk(clk),.addr({t_row,5'b0}+{2'b0,t_row,3'b0}+t_dx[9:3]),.data(template_word));
    wire title_on=caption && y>=357 && y<381 && x>=32 && x<288;
    wire [9:0] title_dx=x-32,title_dy=y-357;
    scene_title_rom u_title(.clk(clk),.addr({active_index,9'b0}+{1'b0,active_index,8'b0}+{2'b0,title_dy[4:0],5'b0}+title_dx[7:3]),.data(title_word));
    wire ticker_on=y>=450 && y<470;
    wire [9:0] ticker_x=x+scroll,ticker_dy=y-450;
    scene_ticker_rom u_ticker(.clk(clk),.addr(active_overview?12'd2560+{1'b0,ticker_dy[4:0],6'b0}+ticker_x[8:3]:{ticker_dy[4:0],7'b0}+ticker_x[9:3]),.data(ticker_word));
    wire logo_on=!active_overview && x>=LOGO_X && x<LOGO_X+192 && y>=LOGO_Y && y<LOGO_Y+48;
    wire [9:0] logo_dx=x-LOGO_X,logo_dy=y-LOGO_Y;
    scene_logo_rom u_logo(.clk(clk),.addr({logo_dy[5:0],logo_dx[7:3]}),.data(logo_word));
    // Grass tile 320x72 repeated twice above the subtitle band; 32-pixel growth bins,
    // bins 0..9 (the louder low ones) on the right half, 10..19 under the caption.
    wire grass_on=y>=GRASS_Y && y<GRASS_Y+GRASS_H;
    wire [9:0] grass_dy=y-GRASS_Y,grass_dx=x>=320?x-10'd320:x;
    wire [15:0] grass_word;
    scene_grass_rom u_grass(.clk(clk),.addr({grass_dy[6:0],6'b0}+{2'b0,grass_dy[6:0],4'b0}+grass_dx[8:2]),.data(grass_word));
    wire [9:0] grass_rx=x-10'd320;
    assign vis_bin=active_visualization==2?(x-SPEC_X)>>3:x>=320?{1'b0,grass_rx[8:5]}:5'd10+x[9:5];

    // ---- stage 1: slot resolution and image adjustment ----
    reg [9:0] x1,y1;reg vs1,de1;
    reg t_on1,title_on1,ticker_on1,logo_on1,grass_on1;reg [3:0] t_grow1;reg [2:0] title_j1,ticker_j1,t_sub1,logo_col1,t_color1;reg t_sel1;
    reg [1:0] grass_col1;
    reg [23:0] adjusted;
    function [7:0] adjust; // frame-stable brightness/contrast, as video_overlay
        input [7:0] color;input [1:0] brightness,contrast;
        reg signed [11:0] value;
        begin
            value=$signed({1'b0,color})-12'sd128;
            if(contrast==0) value=value>>>1;
            else if(contrast==2) value=value<<<1;
            value=value+12'sd128;
            if(brightness==0) value=value-12'sd32;
            else if(brightness==2) value=value+12'sd32;
            adjust=value<0?0:value>255?255:value[7:0];
        end
    endfunction
    reg [4:0] gain_q;
    // Slot glyph = 1+nibble (digit/hex), blank (code 0) or '-' (code 21, unknown size).
    reg [3:0] slot_nib;reg slot_blank,slot_dash;
    wire [4:0] slot_code=slot_blank?5'd0:slot_dash?5'd21:5'd1+slot_nib;
    wire [6:0] slot_id=template_word[6:0];
    wire [1:0] period=active_settings[5:4];
    wire [1:0] page=active_overview?active_focus:active_index;
    always @(*) begin
        slot_nib=0;slot_blank=0;slot_dash=0;
        case(slot_id)
            0:slot_nib={1'b0,page}+1'b1;
            1:slot_nib={1'b0,active_total};
            2:begin slot_nib=load_bcd[15:12];slot_blank=load_bcd[15:12]==0;end
            3:slot_nib=load_bcd[11:8];4:slot_nib=load_bcd[7:4];5:slot_nib=load_bcd[3:0];
            6:begin slot_nib=init_bcd[15:12];slot_blank=init_bcd[15:12]==0;end
            7:slot_nib=init_bcd[11:8];8:slot_nib=init_bcd[7:4];9:slot_nib=init_bcd[3:0];
            10:begin slot_nib=width_bcd[15:12];slot_blank=width_bcd[15:12]==0 || !size_known;end
            11:begin slot_nib=width_bcd[11:8];slot_blank=width_bcd[15:8]==0 || !size_known;end
            12:begin slot_nib=width_bcd[7:4];slot_blank=width_bcd[15:4]==0 || !size_known;end
            13:begin slot_nib=width_bcd[3:0];slot_dash=!size_known;end
            14:begin slot_nib=height_bcd[15:12];slot_blank=height_bcd[15:12]==0 || !size_known;end
            15:begin slot_nib=height_bcd[11:8];slot_blank=height_bcd[15:8]==0 || !size_known;end
            16:begin slot_nib=height_bcd[7:4];slot_blank=height_bcd[15:4]==0 || !size_known;end
            17:begin slot_nib=height_bcd[3:0];slot_dash=!size_known;end
            18:begin slot_nib=zoom_x_bcd[19:16];slot_blank=zoom_x_bcd[19:16]==0 || !size_known;end
            19:begin slot_nib=zoom_x_bcd[15:12];slot_blank=zoom_x_bcd[19:12]==0 || !size_known;end
            20:begin slot_nib=zoom_x_bcd[11:8];slot_blank=!size_known;end
            21:begin slot_nib=zoom_x_bcd[7:4];slot_blank=!size_known;end
            22:begin slot_nib=zoom_x_bcd[3:0];slot_blank=!size_known;end
            23:begin slot_nib=zoom_y_bcd[19:16];slot_blank=zoom_y_bcd[19:16]==0 || !size_known;end
            24:begin slot_nib=zoom_y_bcd[15:12];slot_blank=zoom_y_bcd[19:12]==0 || !size_known;end
            25:begin slot_nib=zoom_y_bcd[11:8];slot_blank=!size_known;end
            26:begin slot_nib=zoom_y_bcd[7:4];slot_blank=!size_known;end
            27:begin slot_nib=zoom_y_bcd[3:0];slot_blank=!size_known;end
            28:slot_nib=time_digits[15:12];29:slot_nib=time_digits[11:8];
            30:slot_nib=time_digits[7:4];31:slot_nib=time_digits[3:0];
            32:slot_nib={1'b0,active_volume};
            33:slot_nib=active_diagnostics[95:92];34:slot_nib=active_diagnostics[91:88];
            35:slot_nib=active_diagnostics[87:84];
            36,37,38,39:slot_nib=active_diagnostics[68+(39-slot_id)*4 +: 4];
            40,41,42,43,44,45,46,47:slot_nib=active_diagnostics[36+(47-slot_id)*4 +: 4];
            48,49,50,51:slot_nib=active_diagnostics[20+(51-slot_id)*4 +: 4];
            52,53,54,55,56:slot_nib=active_diagnostics[(56-slot_id)*4 +: 4];
            57:slot_nib=active_diagnostics[107:104];58:slot_nib=active_diagnostics[103:100];
            59:slot_nib=active_diagnostics[99:96];
            60,61,62,63:slot_nib=misses_q[(63-slot_id)*4 +: 4];
            64:slot_nib={2'b0,minimum_q[9:8]};65:slot_nib=minimum_q[7:4];66:slot_nib=minimum_q[3:0];
            67:slot_nib=active_error;
            68:begin slot_nib=4'd1;slot_blank=period!=3;end
            69:slot_nib=period==0?4'd1:period==1?4'd3:period==2?4'd5:4'd0;
            default:slot_blank=1;
        endcase
    end
    wire t_slot=template_word[15];
    wire [7:0] glyph=t_slot?{3'b0,slot_code}:template_word[7:0];
    wire [11:0] font_addr={glyph[6:0],t_grow1,!t_slot && template_word[14]};
    scene_font_lo_rom u_font_lo(.clk(clk),.addr(font_addr),.data(font_lo_word));
    scene_font_hi_rom u_font_hi(.clk(clk),.addr(font_addr[10:0]),.data(font_hi_word)); // glyphs 128..191
    // Bottom shade: linear ramp from y=224 to 1/2 darker at the bottom, kept in
    // 1/256 steps and spread over the 1/16 gain steps by a 4x4 Bayer dither,
    // folded into the fade gain.
    wire [9:0] shade_dy=y1-10'd224;
    wire [3:0] bayer={x1[0]^y1[0],y1[0],x1[1]^y1[1],y1[1]};
    wire [7:0] shade_fx={1'b0,shade_dy[7:1]}+bayer;
    wire [3:0] shade=active_overview || y1<224?4'd0:shade_fx[7:4];
    wire [9:0] shaded_gain=gain_q*(5'd16-shade);
    wire [4:0] eff_gain=shaded_gain[8:4];
    wire [12:0] faded_r=adjusted[23:16]*eff_gain,faded_g=adjusted[15:8]*eff_gain,faded_b=adjusted[7:0]*eff_gain;

    // ---- stage 2: compose ----
    reg [9:0] x2,y2;reg vs2,de2;
    reg [23:0] bg2;
    reg t_on2,t_sel2,font_hi2;reg [1:0] title_lvl2,ticker_lvl2;reg [2:0] t_sub2;reg [3:0] t_grow2;reg [2:0] t_color2;reg [1:0] logo_code2;
    reg [7:0] bar2,wave2;
    reg [3:0] grass_q2;
    wire [15:0] font_word=font_hi2?font_hi_word:font_lo_word;
    wire [1:0] text_lvl=t_on2?font_word[t_sub2*2 +: 2]:2'd0;
    function [23:0] glass; // half-transparent dark plate
        input [23:0] rgb;
        begin glass={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]}+24'h050908;end
    endfunction
    function [23:0] red_glass;
        input [23:0] rgb;
        begin red_glass={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]}+24'h400a0a;end
    endfunction
    function [23:0] band; // three-quarter dark subtitle band
        input [23:0] rgb;
        begin band={2'b0,rgb[23:18],2'b0,rgb[15:10],2'b0,rgb[7:2]}+24'h030907;end
    endfunction
    function [23:0] quarter; // caption text shadow
        input [23:0] rgb;
        begin quarter={2'b0,rgb[23:18],2'b0,rgb[15:10],2'b0,rgb[7:2]};end
    endfunction
    function [23:0] aa; // ink over rgb at coverage 1/4, 1/2 or full
        input [23:0] rgb,ink;input [1:0] lvl;
        reg [23:0] half_rgb,half_ink;
        begin
            half_rgb={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]};
            half_ink={1'b0,ink[23:17],1'b0,ink[15:9],1'b0,ink[7:1]};
            case(lvl)
                1:aa=half_rgb+{1'b0,half_rgb[23:17],1'b0,half_rgb[15:9],1'b0,half_rgb[7:1]}
                     +{1'b0,half_ink[23:17],1'b0,half_ink[15:9],1'b0,half_ink[7:1]};
                2:aa=half_rgb+half_ink;
                3:aa=ink;
                default:aa=rgb;
            endcase
        end
    endfunction
    function [23:0] logo_blend;
        input [23:0] rgb;
        begin logo_blend={2'b11,rgb[23:18],2'b11,rgb[15:10],2'b11,rgb[7:2]};end
    endfunction
    function rounded; // inside a w x h box at (dx,dy) with radius-6 corners
        input [9:0] dx,dy,w,h;
        reg [9:0] r;reg [2:0] inset;
        begin
            r=dy<6?dy:h-1'b1-dy;
            case(r) 0:inset=4;1:inset=2;2,3:inset=1;default:inset=0; endcase
            rounded=dx<w && dy<h && dx>=inset && dx<w-inset;
        end
    endfunction
    function [23:0] text_rgb;
        input [2:0] kind;
        begin case(kind) 1:text_rgb=GREEN;2:text_rgb=ALERT;3:text_rgb=GOLD;4:text_rgb=BODY;default:text_rgb=WHITE; endcase end
    endfunction
    // Grass growth per 32-pixel bin: a pixel shows while its blade position is below
    // the level. The level jumps up with the spectrum (5 quiet .. 15 full) and falls one
    // step every fourth frame; under the caption it stays at most 6.
    wire [9:0] spec_dx=x2-SPEC_X;
    wire spec_area=spec_dx<256;
    wire grass_mode=active_visualization==1 && !active_overview;
    wire wave_on=active_visualization==2 && !active_overview;
    wire [7:0] bar_capped=bar2>96?8'd96:bar2;
    wire [4:0] grow_sum=5'd5+bar_capped[7:3];
    wire [3:0] grow_target=!spectrum_valid?4'd5:grow_sum>15?4'd15:grow_sum[3:0];
    reg [3:0] grow[0:19];
    wire [9:0] grass_rx2=x2-10'd320;
    wire [4:0] grass_bin2=x2>=320?{1'b0,grass_rx2[8:5]}:5'd10+x2[9:5];
    wire [3:0] grow_bin=grow[grass_bin2];
    wire [3:0] grow_here=x2<344 && grow_bin>6?4'd6:grow_bin;
    wire [4:0] grass_tip={1'b0,grass_q2}+5'd4;
    wire grass_bit=grass_mode && grass_q2<grow_here;
    wire [2:0] grass_tone={1'b0,grass_q2[3:2]}+(grow_here>=12 && grass_tip>=grow_here);
    reg [23:0] grass_color;
    always @(*) case(grass_tone)
        0:grass_color=24'h122016;1:grass_color=24'h28422a;2:grass_color=24'h4e7042;
        3:grass_color=24'h84a260;default:grass_color=24'hc4cc80;
    endcase
    // Caption shadow: ink of the previous row, one pixel to the left, from a 512-pixel
    // line buffer of caption ink (title and body rows).
    wire cap_ink=caption && y2>=340 && (title_lvl2[1] || text_lvl[1]);
    reg [15:0] ink_line[0:31];
    reg [15:0] ink_shift,ink_above_q;
    reg ink_above_d;
    wire [15:0] ink_above=x2[3:0]==0?ink_line[x2[8:4]]:ink_above_q;
    always @(posedge clk) if(de2) begin
        ink_shift<={cap_ink,ink_shift[15:1]};
        if(x2[3:0]==15 && !x2[9]) ink_line[x2[8:4]]<={cap_ink,ink_shift[15:1]};
        if(x2[3:0]==0) ink_above_q<=ink_above;
        ink_above_d<=ink_above[x2[3:0]];
    end
    wire shadow_bit=caption && ink_above_d && y2>=358 && y2<412 && x2<360;
    wire signed [7:0] wave_sample=wave2;
    wire signed [10:0] wave_y=11'sd396-($signed(wave_sample)>>>2);
    wire [2:0] dot_n=active_total==0?3'd1:active_total>4?3'd4:active_total;
    reg dot_pixel,dot_active;
    integer i;
    // Centres 14 px apart around x=320; the current page is a 16x6 pill.
    wire [9:0] dot_dx=x2+{dot_n,3'b0}-dot_n-10'd324; // x2+7*(dot_n-1)-317
    always @(*) begin
        dot_pixel=0;dot_active=0;
        for(i=0;i<4;i=i+1) if(i<dot_n) begin
            if(i==active_index) begin
                if(rounded(dot_dx+10'd5-14*i,y2-10'd339,10'd16,10'd6)) begin dot_pixel=1;dot_active=1;end
            end else if(dot_dx-14*i<6 && y2>=339 && y2<345 &&
                        !((dot_dx==14*i || dot_dx==14*i+5) && (y2==339 || y2==344))) dot_pixel=1;
        end
    end
    reg [23:0] pix;
    always @(*) begin
        pix=bg2;
        if(y2>=444 && y2<476) pix=y2==444?GREEN:band(bg2);
        if(wave_on && y2==SPEC_BASE+1 && x2>=344 && x2<616) pix=BASELINE;
        if(grass_bit) pix=grass_color;
        if(wave_on && spec_area) begin
            if(y2==396) pix=WAVE_AXIS;
            if(wave_valid && $signed({1'b0,y2})>=wave_y-1 && $signed({1'b0,y2})<=wave_y+1) pix=WAVE;
        end
        if(wave_on && x2>=620 && x2<626 && y2<SPEC_BASE && y2>=SPEC_BASE-(wave_peak>>2)) pix=PEAK;
        if(caption) begin
            if(x2>=16 && x2<20 && y2>=360 && y2<420) pix=GREEN;
            if(shadow_bit) pix=quarter(bg2);
            if(dot_n>1 && dot_pixel) pix=dot_active?GREEN:DOT;
        end
        if(card) begin
            if(rounded(x2-10'd12,y2-10'd44,card_right-10'd12,card_bottom-10'd44)) pix=glass(bg2);
            if(x2>=12 && x2<15 && y2>=52 && y2<card_bottom-8) pix=diag?ALERT:GREEN;
            if(t_sel2 && x2>=17 && x2<21 && t_grow2>=4 && t_grow2<12) pix=GOLD;
        end
        if(rounded(x2-10'd12,y2-10'd10,pill_right-10'd12,10'd26)) pix=fault?red_glass(bg2):glass(bg2);
        if(x2>=24 && x2<30 && y2>=20 && y2<26) pix=fault?RED_DOT:GREEN;
        if(!active_overview && rounded(x2-10'd430,y2-10'd8,10'd204,10'd56))
            pix=logo_code2==1?LOGO_NAVY:logo_code2==2?LOGO_RED:logo_blend(bg2);
        // Title, template text and ticker rows are disjoint: one blend serves all three.
        pix=aa(pix,text_lvl!=0?text_rgb(t_color2):WHITE,text_lvl|title_lvl2|ticker_lvl2);
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_d<=0;x<=0;y<=0;card_k<=0;card_off<=0;x1<=0;y1<=0;x2<=0;y2<=0;vs1<=0;de1<=0;vs2<=0;de2<=0;o_vs<=0;o_de<=0;o_rgb<=0;
            active_settings<=16'h05c8;active_error<=0;active_auto<=0;active_overview<=0;active_media<=0;parity<=0;
            active_volume<=4;active_total<=0;active_transition<=0;active_visualization<=1;active_focus<=0;active_index<=0;
            active_diagnostics<=0;misses_q<=0;minimum_q<=0;scroll<=0;time_digits<=0;info_q<=0;load_q<=0;
            t_on1<=0;title_on1<=0;ticker_on1<=0;logo_on1<=0;t_grow1<=0;title_j1<=0;ticker_j1<=0;t_sub1<=0;logo_col1<=0;
            t_color1<=0;t_sel1<=0;adjusted<=0;gain_q<=16;
            bg2<=0;t_on2<=0;t_sel2<=0;title_lvl2<=0;ticker_lvl2<=0;font_hi2<=0;t_sub2<=0;t_grow2<=0;t_color2<=0;
            logo_code2<=0;bar2<=0;wave2<=0;grass_on1<=0;grass_col1<=0;grass_q2<=4'd15;
            for(p=0;p<20;p=p+1) grow[p]<=4'd5;
        end else begin
            vs_d<=i_vs;
            if(frame_start) begin
                active_settings<=settings;active_error<=error_code;active_auto<=auto_enabled;
                active_overview<=overview;active_media<=media_valid;active_index<=image_index;active_total<=image_total;
                active_volume<=volume;active_transition<=transition_kind;active_visualization<=visualization;
                active_focus<=focus;active_diagnostics<=diagnostics;misses_q<=wav_misses;minimum_q<=wav_minimum;
                time_digits<={min_ten,min_one,sec_ten,sec_one};info_q<=media_info;load_q<=load_centis;
                parity<=~parity;if(parity) scroll<=scroll+1'b1;
                x<=0;y<=0;card_k<=0;card_off<=0;
            end else if(i_de) begin
                if(x==WIDTH-1) begin
                    x<=0;y<=y==HEIGHT-1?0:y+1'b1;
                    if(y==HEIGHT-1 || y<48) begin card_k<=0;card_off<=0;end
                    else if(card_off==19) begin card_off<=0;if(card_k!=31) card_k<=card_k+1'b1;end
                    else card_off<=card_off+1'b1;
                end
                else x<=x+1'b1;
            end
            // stage 1
            x1<=x;y1<=y;vs1<=i_vs;de1<=i_de;
            t_on1<=t_inside;t_grow1<=t_grow;t_sub1<=t_dx[2:0];t_color1<=t_color;t_sel1<=t_sel;
            title_on1<=title_on;title_j1<=title_dx[2:0];ticker_on1<=ticker_on;ticker_j1<=ticker_x[2:0];
            logo_on1<=logo_on;logo_col1<=logo_dx[2:0];grass_on1<=grass_on;grass_col1<=grass_dx[1:0];
            gain_q<=fade_gain;
            adjusted<=image_valid?{adjust(i_rgb[23:16],active_settings[11:10],active_settings[9:8]),
                adjust(i_rgb[15:8],active_settings[11:10],active_settings[9:8]),
                adjust(i_rgb[7:0],active_settings[11:10],active_settings[9:8])}:24'd0;
            // stage 2
            x2<=x1;y2<=y1;vs2<=vs1;de2<=de1;
            bg2<={faded_r[11:4],faded_g[11:4],faded_b[11:4]};
            t_on2<=t_on1;t_sub2<=t_sub1;font_hi2<=glyph[7];
            t_grow2<=t_grow1;t_color2<=t_color1;t_sel2<=t_sel1;
            title_lvl2<=title_on1?title_word[title_j1*2 +: 2]:2'd0;
            ticker_lvl2<=ticker_on1?ticker_word[ticker_j1*2 +: 2]:2'd0;
            logo_code2<=logo_on1?logo_word[logo_col1*2 +: 2]:2'd0;
            bar2<=spectrum_bar;wave2<=wave_bar;
            grass_q2<=grass_on1?grass_word[grass_col1*4 +: 4]:4'd15;
            if(de2 && y2==352 && x2[4:0]==0)
                grow[grass_bin2]<=grow_target>=grow_bin?grow_target:(parity && scroll[0] && grow_bin>5)?grow_bin-1'b1:grow_bin;
            // output
            o_vs<=vs2;o_de<=de2;o_rgb<=de2?pix:24'd0;
        end
    end
endmodule
