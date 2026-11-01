`timescale 1ns/1ps
// Two-stage pipeline: adjust bottom image, then draw OSD with frame-stable settings.
module video_overlay #(
    parameter WIDTH=640,HEIGHT=480,DIAGNOSTICS=0,FADE=0,ENHANCED=0,ADVANCED=0,LOGO=ADVANCED,CLK_HZ=25_000_000
)(
    input wire clk,rst,i_vs,i_de,image_valid,input wire [23:0] i_rgb,
    input wire [15:0] settings,input wire [3:0] error_code,
    input wire [1:0] image_index,input wire media_valid,auto_enabled,
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
    reg vs_d;
    reg [1:0] active_visualization,active_focus;
    reg active_overview;
    reg [15:0] misses_q;
    reg [9:0] minimum_q;
    wire [9:0] ticker_y=ADVANCED && active_overview?416:304;
    localparam [511:0] BROWSE_MESSAGE="KEY2 NEXT   KEY4 SELECT   HOLD KEY4 BACK   GOLD FOCUS           ";
    localparam [511:0] ADVANCED_MESSAGE="PIC:1  STAY ON THE TRAIL  NO FIRE  TAKE LITTER HOME  KEY2 NEXT  ";
    reg [9:0] x,y,sx,sy;
    reg s_vs,s_de;
    reg [23:0] adjusted;
    reg [4:0] gain_q;
    wire [12:0] faded_r=adjusted[23:16]*gain_q;
    wire [12:0] faded_g=adjusted[15:8]*gain_q;
    wire [12:0] faded_b=adjusted[7:0]*gain_q;
    wire [23:0] background=FADE?{faded_r[11:4],faded_g[11:4],faded_b[11:4]}:adjusted;
    reg [3:0] active_error;
    reg active_auto;
    reg [2:0] active_volume;
    reg [1:0] active_transition;
    reg [24:0] second_ticks;
    reg [3:0] sec_one,sec_ten,min_one,min_ten;
    reg [15:0] time_digits;
    reg [9:0] scroll;
    reg scroll_div;
    wire [9:0] ticker_x=sx+scroll;
    localparam [511:0] MESSAGE="PIC:1   NEXT KEY2   AUTO KEY4   MENU HOLD KEY2 KEY4             ";
    wire [5:0] ticker_column=ticker_x[9:4];
    function [23:0] panel_blend;
        input [23:0] rgb;
        begin panel_blend={1'b0,rgb[23:17],1'b0,rgb[15:9],1'b0,rgb[7:1]}+24'h0c1018;end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin second_ticks<=0;sec_one<=0;sec_ten<=0;min_one<=0;min_ten<=0;end
        else if(ENHANCED) begin
            if(second_ticks==CLK_HZ-1) begin
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
    end
    reg [108:0] active_diagnostics;
    wire debug_panel=DIAGNOSTICS && active_diagnostics[108];
    // Media info rows: BMP size, zoom x100, first-image time (centiseconds from
    // reset until the first image is shown) and SD init time (centiseconds
    // from SD-domain reset until the card is initialized).
    localparam integer CENTI=CLK_HZ/100;
    reg [32:0] info_q;
    reg [$clog2(CENTI)-1:0] centi_ticks;
    reg [13:0] load_centis,load_q;
    reg load_shown;
    wire [11:0] init_centis=info_q[32:21];
    wire [19:0] width_bcd,height_bcd,zoom_x_bcd,zoom_y_bcd,rate_bcd,load_bcd;
    wire info_rows=ENHANCED && active_settings[7] && !active_settings[15] && !debug_panel;
    wire size_known=info_q[10:0]!=0 && info_q[20:11]!=0;
    osd_bcd_fields u_fields(.clk(clk),.rst(rst),
        .width(info_q[10:0]),.height(info_q[20:11]),.rate_x5({3'b0,init_centis}),.load(load_q),
        .width_bcd(width_bcd),.height_bcd(height_bcd),.zoom_x_bcd(zoom_x_bcd),.zoom_y_bcd(zoom_y_bcd),
        .rate_bcd(rate_bcd),.load_bcd(load_bcd));
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
    // Decimal digit, blanked while it is a leading zero.
    function [7:0] digit;
        input [3:0] value;input blank;
        begin digit=blank?" ":"0"+value;end
    endfunction
    function [7:0] hex_char;
        input [3:0] value;
        begin hex_char=value<10?"0"+value:"A"+(value-10);end
    endfunction
    assign frame_start=i_vs && !vs_d;
    function [7:0] adjust;
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
    // Each row occupies five bits, top row first. Small original 5x7 bitmap font.
    function [34:0] glyph;
        input [7:0] c;
        begin case(c)
            "0":glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1":glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2":glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "3":glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            "4":glyph={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            "5":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "6":glyph={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            "7":glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "8":glyph={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            "9":glyph={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            "A":glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "B":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "C":glyph={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            "D":glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "E":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "F":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "G":glyph={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
            "H":glyph={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "N":glyph={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
            "L":glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "O":glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "P":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "R":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "Y":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
            "I":glyph={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "M":glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            "S":glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "T":glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "U":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "K":glyph={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
            "V":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
            "X":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
            "-":glyph={5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
            ":":glyph={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
            ".":glyph={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100};
            "/":glyph={5'b00001,5'b00010,5'b00010,5'b00100,5'b01000,5'b01000,5'b10000};
            "Z":glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
            default:glyph=0;
        endcase end
    endfunction
    wire [9:0] tx=sx-16,ty=sy>=112?sy-112:sy>=88?sy-88:sy>=64?sy-64:sy>=40?sy-40:sy-16;
    wire [4:0] column=tx[8:4];
    reg [7:0] character;
    reg [34:0] bits;
    reg text_pixel;
    wire panel=active_settings[7] || active_settings[15];
    // Bin addressed from x one cycle ahead (as the logo ROM), so it lines up with sx.
    assign vis_bin=(x-64)>>4;
    wire [7:0] bar=spectrum_bar;
    wire [7:0] bar_height=bar>96?96:bar;
    // Spectrum gradient by row, registered with sy so it adds no pixel-path compare.
    reg [23:0] bar_color;
    // Official logo (logo_rom.v) on a 3/4-white plate below the OSD panel. The ROM
    // is addressed from x/y one cycle ahead, so its data lines up with sx/sy.
    localparam [9:0] LOGO_X=472,LOGO_Y=140;
    wire [9:0] logo_dx=x-LOGO_X,logo_dy=y-LOGO_Y;
    wire [15:0] logo_word;
    reg logo_area,logo_plate;
    reg [2:0] logo_column;
    wire [1:0] logo_code=logo_word[logo_column*2 +: 2];
    generate if(LOGO) begin: logo
        logo_rom u_logo(.clk(clk),.addr({logo_dy[4:0],logo_dx[7:3]}),.data(logo_word));
    end else begin: no_logo
        assign logo_word=16'd0;
    end endgenerate
    function [23:0] logo_blend;
        input [23:0] rgb;
        begin logo_blend={2'b11,rgb[23:18],2'b11,rgb[15:10],2'b11,rgb[7:2]};end
    endfunction
    wire signed [7:0] wave_sample=wave_bar;
    wire signed [10:0] wave_y=11'sd400-($signed(wave_sample)>>>2);
    wire wave_pixel=wave_valid && sx>=64 && sx<576 && sy>=368 && sy<434 &&
        $signed({1'b0,sy})>=wave_y-1 && $signed({1'b0,sy})<=wave_y+1;
    wire peak_pixel=sx>=584 && sx<596 && sy>=432-(wave_peak>>1) && sy<432;
    always @(*) begin
        character=" ";
        if(sy<40) case(column)
            0:character="F";1:character="P";2:character="G";3:character="A";
            5:character="P";6:character="L";7:character="A";8:character="Y";9:character="E";10:character="R";
            12:character="E";13:character=":";14:character=active_error<10?"0"+active_error:"A"+(active_error-10);
            16:character="P";17:character="I";18:character="C";19:character=":";
            20:character=media_valid?("1"+image_index):"-";
            23:character="A";24:character="U";25:character="T";26:character="O";27:character=":";28:character="0"+active_auto;
        endcase
        else if(sy<64) case(column)
            0:character="B";1:character=":";2:character="0"+active_settings[11:10];
            4:character="C";5:character=":";6:character="0"+active_settings[9:8];
            8:character="O";9:character=":";10:character="0"+active_settings[7];
            12:character="F";13:character=":";14:character="0"+(ADVANCED?active_visualization:{1'b0,active_settings[6]});
            16:character="P";17:character=":";18:character=active_settings[5:4]==3?"1":"0";
            19:case(active_settings[5:4]) 0:character="1";1:character="3";2:character="5";3:character="0";endcase
            20:character="S";21:character=":";22:character=active_settings[3]?"M":"T";
            24:if(ENHANCED) character="V";25:if(ENHANCED) character=":";26:if(ENHANCED) character="0"+active_volume;
            28:if(ENHANCED) character="T";29:if(ENHANCED) character=":";30:if(ENHANCED) character="0"+active_transition;
        endcase
        else if(sy<88) case(column)
            0:character="I";1:character=":";2:character=hex_char(active_diagnostics[95:92]);
            4:character="B";5:character=":";6:character=hex_char(active_diagnostics[91:88]);
            8:character="N";9:character=":";10:character=hex_char(active_diagnostics[87:84]);
            12:character="F";13:character=":";
            14,15,16,17:character=hex_char(active_diagnostics[68+(17-column)*4 +: 4]);
        endcase
        else if(sy<112) case(column)
            0:character="L";1:character=":";
            2,3,4,5,6,7,8,9:character=hex_char(active_diagnostics[36+(9-column)*4 +: 4]);
            11:character="H";12:character=":";
            13,14,15,16:character=hex_char(active_diagnostics[20+(16-column)*4 +: 4]);
        endcase
        else case(column)
            0:character="P";1:character=":";
            2,3,4,5,6:character=hex_char(active_diagnostics[(6-column)*4 +: 4]);
            8:character="R";9:character=":";10:character=hex_char(active_diagnostics[107:104]);
            11:character="-";12:character=hex_char(active_diagnostics[103:100]);
            13:character=hex_char(active_diagnostics[99:96]);
        endcase
        if(ENHANCED && !debug_panel && sy>=64 && sy<78) begin
            case(column)
                0:character="T";1:character="I";2:character="M";3:character="E";4:character=":";
                6:character="0"+time_digits[15:12];7:character="0"+time_digits[11:8];8:character=":";
                9:character="0"+time_digits[7:4];10:character="0"+time_digits[3:0];
                13:character="P";14:character="I";15:character="C";16:character=":";
                17:character=ADVANCED && active_overview?"1"+active_focus:media_valid?"1"+image_index:"-";
                19:if(ADVANCED) character="L";20:if(ADVANCED) character=":";
                21:if(ADVANCED) character=hex_char({2'b0,minimum_q[9:8]});
                22:if(ADVANCED) character=hex_char(minimum_q[7:4]);23:if(ADVANCED) character=hex_char(minimum_q[3:0]);
                25:if(ADVANCED) character="U";26:if(ADVANCED) character=":";
                27,28,29,30:if(ADVANCED) character=hex_char(misses_q[(30-column)*4 +: 4]);
                default:character=" ";
            endcase
        end
        if(info_rows && sy>=88 && sy<102) begin
            case(column)
                0:character="B";1:character="M";2:character="P";3:character=":";
                4:character=digit(width_bcd[15:12],width_bcd[15:12]==0 || !size_known);
                5:character=digit(width_bcd[11:8],width_bcd[15:8]==0 || !size_known);
                6:character=digit(width_bcd[7:4],width_bcd[15:4]==0 || !size_known);
                7:character=size_known?"0"+width_bcd[3:0]:"-";
                8:character="X";
                9:character=digit(height_bcd[11:8],height_bcd[11:8]==0 || !size_known);
                10:character=digit(height_bcd[7:4],height_bcd[11:4]==0 || !size_known);
                11:character=size_known?"0"+height_bcd[3:0]:"-";
                13:character="Z";14:character="O";15:character="O";16:character="M";17:character=":";
                18:character=digit(zoom_x_bcd[19:16],zoom_x_bcd[19:16]==0 || !size_known);
                19:character=digit(zoom_x_bcd[15:12],zoom_x_bcd[19:12]==0 || !size_known);
                20:character=digit(zoom_x_bcd[11:8],!size_known);21:character=size_known?".":" ";
                22:character=digit(zoom_x_bcd[7:4],!size_known);23:character=digit(zoom_x_bcd[3:0],!size_known);
                24:character=size_known?"X":" ";
                25:character=digit(zoom_y_bcd[19:16],zoom_y_bcd[19:16]==0 || !size_known);
                26:character=digit(zoom_y_bcd[15:12],zoom_y_bcd[19:12]==0 || !size_known);
                27:character=digit(zoom_y_bcd[11:8],!size_known);28:character=size_known?".":" ";
                29:character=digit(zoom_y_bcd[7:4],!size_known);30:character=digit(zoom_y_bcd[3:0],!size_known);
                default:character=" ";
            endcase
        end
        if(info_rows && sy>=112 && sy<126) begin
            case(column)
                0:character="L";1:character="O";2:character="A";3:character="D";4:character=":";
                5:character="0"+load_bcd[15:12];6:character="0"+load_bcd[11:8];7:character=".";
                8:character="0"+load_bcd[7:4];9:character="0"+load_bcd[3:0];10:character="S";
                12:character="I";13:character="N";14:character="I";15:character="T";16:character=":";
                17:character="0"+rate_bcd[15:12];18:character="0"+rate_bcd[11:8];19:character=".";
                20:character="0"+rate_bcd[7:4];21:character="0"+rate_bcd[3:0];22:character="S";
                default:character=" ";
            endcase
        end
        if(ENHANCED && sy>=ticker_y && sy<ticker_y+14) begin
            if(ADVANCED && active_overview) character=BROWSE_MESSAGE[511-ticker_column*8 -: 8];
            else if(ADVANCED) character=ADVANCED_MESSAGE[511-ticker_column*8 -: 8];
            else character=MESSAGE[511-ticker_column*8 -: 8];
            if(ticker_column==4 && !(ADVANCED && active_overview)) character=media_valid?"1"+image_index:"-";
        end
        bits=glyph(character);
        text_pixel=0;
        if(sx>=16 && sx<(ENHANCED?528:480) && ((sy>=16 && sy<30)||(sy>=40 && sy<54)||
            ((debug_panel || ENHANCED) && ((sy>=64 && sy<78)||(sy>=88 && sy<102)||(sy>=112 && sy<126)))) && tx[3:1]<5)
            text_pixel=bits[34-ty[3:1]*5-tx[3:1]];
        if(ENHANCED && sy>=ticker_y && sy<ticker_y+14) begin
            text_pixel=0;
            if(ticker_x[3:1]<5) text_pixel=bits[34-((sy-ticker_y)>>1)*5-ticker_x[3:1]];
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            active_visualization<=1;active_focus<=0;active_overview<=0;misses_q<=0;minimum_q<=0;
            vs_d<=0;x<=0;y<=0;sx<=0;sy<=0;s_vs<=0;s_de<=0;adjusted<=0;bar_color<=0;logo_area<=0;logo_plate<=0;logo_column<=0;
            o_vs<=0;o_de<=0;o_rgb<=0;active_settings<=16'h05c8;active_error<=0;active_auto<=0;
            active_diagnostics<=0;gain_q<=16;active_volume<=4;active_transition<=0;time_digits<=0;scroll<=0;scroll_div<=0;
            info_q<=0;load_q<=0;
        end else begin
            vs_d<=i_vs;
            if(frame_start) begin
                active_volume<=volume;active_transition<=transition_kind;
                active_visualization<=visualization;active_focus<=focus;active_overview<=overview;
                misses_q<=wav_misses;minimum_q<=wav_minimum;
                time_digits<={min_ten,min_one,sec_ten,sec_one};
                info_q<=media_info;load_q<=load_centis;
                if(ENHANCED) begin scroll_div<=~scroll_div;if(scroll_div) scroll<=scroll+1'b1;end
                x<=0;y<=0;active_settings<=settings;active_error<=error_code;active_auto<=auto_enabled;active_diagnostics<=diagnostics;end
            else if(i_de) begin
                if(x==WIDTH-1) begin x<=0;y<=y==HEIGHT-1?0:y+1'b1;end
                else x<=x+1'b1;
            end
            sx<=x;sy<=y;s_vs<=i_vs;s_de<=i_de;
            bar_color<=y>=424?24'h40e0a0:y>=400?24'h90e050:y>=376?24'he0d040:24'hff8040;
            logo_area<=x>=LOGO_X && x<LOGO_X+160 && y>=LOGO_Y && y<LOGO_Y+32;
            logo_plate<=LOGO && x>=LOGO_X-4 && x<LOGO_X+164 && y>=LOGO_Y-4 && y<LOGO_Y+36;
            logo_column<=logo_dx[2:0];
            gain_q<=fade_gain;
            adjusted<=image_valid?{adjust(i_rgb[23:16],active_settings[11:10],active_settings[9:8]),
                       adjust(i_rgb[15:8],active_settings[11:10],active_settings[9:8]),
                       adjust(i_rgb[7:0],active_settings[11:10],active_settings[9:8])}:24'd0;
            o_vs<=s_vs;o_de<=s_de;o_rgb<=s_de?background:24'd0;
            if(s_de) begin
                if(logo_plate && !(ADVANCED && active_overview))
                    o_rgb<=logo_area && logo_code==1?24'h122041:logo_area && logo_code==2?24'hcd1220:logo_blend(background);
                if(panel && sx>=12 && sx<(ENHANCED?532:484) && sy>=12 && sy<(ENHANCED && !debug_panel?84:60)) begin
                    o_rgb<=text_pixel?24'hffffff:(ENHANCED?panel_blend(background):24'h182030);
                    if(active_settings[15] && sy[9:1]==9'd28 && sx>=16 && sx<(ENHANCED?528:400) && column[4:2]==active_settings[14:12]) o_rgb<=24'hffcc40;
                end
                if(info_rows && sx>=12 && sx<532 && sy>=84 && sy<132)
                    o_rgb<=text_pixel?24'hffffff:panel_blend(background);
                if(debug_panel && sx>=12 && sx<484 && sy>=60 && sy<132)
                    o_rgb<=text_pixel?24'hffffff:(ENHANCED?panel_blend(background):24'h182030);
                if(ENHANCED && (panel || (ADVANCED && active_overview)) && sy>=ticker_y-4 && sy<ticker_y+18)
                    o_rgb<=text_pixel?24'hffffff:panel_blend(background);
                if((ADVANCED?active_visualization==1 && !active_overview:active_settings[6]) && spectrum_valid && sx>=64 && sx<576 && sy>=352 && sy<448 && sx[3:0]<14 && sy>=448-bar_height)
                    o_rgb<=bar_color;
                if(ADVANCED && !active_overview && active_visualization==2) begin
                    if(sx>=64 && sx<576 && sy==400) o_rgb<=24'h406060;
                    if(wave_pixel) o_rgb<=24'h20ff90;
                    if(peak_pixel) o_rgb<=24'hffb020;
                end
                if(ADVANCED && active_settings[15] && active_settings[14:12]<2 && sy>=86 && sy<92 && sx>=16 && sx<112) begin
                    if(sx[4:0]<28)
                        o_rgb<=((sx-16)>>5)<=(active_settings[14:12]==0?active_settings[11:10]:active_settings[9:8])?24'hffcc40:24'h304050;
                end
            end
        end
    end
endmodule

// One shared divide + double-dabble engine, cycling through six fields
// (33 clocks each): width, height, 64000/width and 48000/height (zoom x100),
// SD rate and first-image time, each as five BCD digits.
module osd_bcd_fields(
    input wire clk,rst,
    input wire [10:0] width,input wire [9:0] height,input wire [14:0] rate_x5,input wire [13:0] load,
    output reg [19:0] width_bcd,height_bcd,zoom_x_bcd,zoom_y_bcd,rate_bcd,load_bcd
);
    reg [2:0] field;
    reg [5:0] step;
    reg [15:0] quotient,divisor,remainder;
    reg [19:0] bcd;
    wire [15:0] shifted={remainder[14:0],quotient[15]};
    wire fits=shifted>=divisor;
    function [19:0] add3;
        input [19:0] value;
        integer n;
        begin
            add3=value;
            for(n=0;n<5;n=n+1) if(value[n*4 +: 4]>=5) add3[n*4 +: 4]=value[n*4 +: 4]+4'd3;
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            field<=0;step<=32;quotient<=0;divisor<=1;remainder<=0;bcd<=0;
            width_bcd<=0;height_bcd<=0;zoom_x_bcd<=0;zoom_y_bcd<=0;rate_bcd<=0;load_bcd<=0;
        end else if(step==32) begin
            // Store the finished field, then latch the next operands.
            case(field)
                0:width_bcd<=bcd;1:height_bcd<=bcd;2:zoom_x_bcd<=bcd;
                3:zoom_y_bcd<=bcd;4:rate_bcd<=bcd;default:load_bcd<=bcd;
            endcase
            case(field==5?3'd0:field+1'b1)
                0:begin quotient<=width;divisor<=1;end
                1:begin quotient<=height;divisor<=1;end
                2:begin quotient<=16'd64000;divisor<=width;end
                3:begin quotient<=16'd48000;divisor<=height;end
                4:begin quotient<=rate_x5;divisor<=1;end
                default:begin quotient<=load;divisor<=1;end
            endcase
            field<=field==5?3'd0:field+1'b1;
            remainder<=0;bcd<=0;step<=0;
        end else if(step<16) begin
            remainder<=fits?shifted-divisor:shifted;
            quotient<={quotient[14:0],fits};
            step<=step+1'b1;
        end else begin
            bcd<={add3(bcd),quotient[15]};
            quotient<={quotient[14:0],1'b0};
            step<=step+1'b1;
        end
    end
endmodule

// SD-domain source for the media info rows: per-slot BMP size latched when a
// load completes (reported for the displayed slot) and the SD init time,
// counted in centiseconds from reset until init_done first rises.
module osd_sd_meter #(parameter integer CLK_FREQ_HZ=100_000_000)(
    input wire clk,rst,init_done,load_done,
    input wire [1:0] load_slot,shown_slot,
    input wire [10:0] width,input wire [9:0] height,
    output wire [32:0] info
);
    localparam integer CENTI=CLK_FREQ_HZ/100;
    reg [83:0] sizes;
    reg [$clog2(CENTI)-1:0] ticks;
    reg [11:0] init_centis;
    reg init_seen;
    assign info={init_centis,sizes[shown_slot*21 +: 21]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin sizes<=0;ticks<=0;init_centis<=0;init_seen<=0;end
        else begin
            if(load_done) sizes[load_slot*21 +: 21]<={height,width};
            if(init_done) init_seen<=1;
            else if(!init_seen) begin
                if(ticks==CENTI-1) begin
                    ticks<=0;
                    if(init_centis!=12'hfff) init_centis<=init_centis+1'b1;
                end else ticks<=ticks+1'b1;
            end
        end
    end
endmodule
