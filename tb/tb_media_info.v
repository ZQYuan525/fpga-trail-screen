`timescale 1ns/1ps
// OSD media info rows (BMP size, zoom x100, first-image time, SD
// init time) and the SD-domain meter that feeds them.
module tb_media_info;
    reg clk=0,rst=1,vs=0,de=0,media_valid=0;
    always #5 clk=~clk;
    wire ovs,ode,fs;wire [23:0] rgb;wire [15:0] active;
    reg [15:0] settings=16'h0588;
    reg [108:0] diag=0;
    reg [32:0] info=0;
    integer x,y,c,n;
    reg [8*31-1:0] row_a,row_b;
    video_overlay #(.ENHANCED(1),.DIAGNOSTICS(1),.CLK_HZ(100000)) dut(.clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.image_valid(1'b1),
        .i_rgb(24'h4080c0),.settings(settings),.error_code(4'd0),.image_index(2'd0),.media_valid(media_valid),.auto_enabled(1'b0),
        .spectrum_bar(8'd0),.spectrum_valid(1'b0),.diagnostics(diag),.fade_gain(5'd16),.volume(3'd4),.transition_kind(2'd0),
        .media_info(info),.o_vs(ovs),.o_de(ode),.o_rgb(rgb),.frame_start(fs),.active_settings(active),.vis_bin());
    // Characters are sampled mid-cell from the overlay's own raster position;
    // output pixels are checked two pipeline stages later via n.
    always @(negedge clk) if(!rst) begin
        if(dut.sx[3:0]==8 && dut.sx>=16 && dut.sx<16+31*16) begin
            c=(dut.sx-16)>>4;
            if(dut.sy==90) row_a[8*(30-c) +: 8]=dut.character;
            if(dut.sy==114) row_b[8*(30-c) +: 8]=dut.character;
        end
    end
    reg [23:0] pixel_panel,pixel_below;
    always @(negedge clk) if(!rst && ode) begin
        if(n==86*640+500) pixel_panel=rgb;
        if(n==140*640+500) pixel_below=rgb;
        n=n+1;
    end
    task draw;
        begin
            @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(300) @(negedge clk);n=0;
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin @(negedge clk);de=1;end
                @(negedge clk);de=0;repeat(4) @(negedge clk);
            end
            repeat(4) @(negedge clk);
        end
    endtask
    task show(input [10:0] w,input [9:0] h,input [11:0] init_centis,input [8*31-1:0] expect_a);
        begin
            info={init_centis,h,w};draw();draw();
            if(row_a!==expect_a) $fatal(1,"FAIL size row %0dx%0d: '%s' expected '%s'",w,h,row_a,expect_a);
        end
    endtask
    // SD meter: init time in 10-cycle centiseconds, per-slot sizes, displayed-slot select.
    reg mclk=0,mrst=1,init_done=0,load_done=0;
    reg [1:0] load_slot=0,shown_slot=0;
    reg [10:0] mw=0;reg [9:0] mh=0;
    wire [32:0] minfo;
    always #5 mclk=~mclk;
    osd_sd_meter #(.CLK_FREQ_HZ(1000)) meter(.clk(mclk),.rst(mrst),.init_done(init_done),.load_done(load_done),
        .load_slot(load_slot),.shown_slot(shown_slot),.width(mw),.height(mh),.info(minfo));
    task load(input [1:0] slot,input [10:0] w,input [9:0] h);
        begin @(negedge mclk);load_slot=slot;mw=w;mh=h;load_done=1;@(negedge mclk);load_done=0;mw=0;mh=0;end
    endtask
    integer k;
    initial begin
        repeat(4) @(negedge mclk);mrst=0;
        load(0,1280,960);load(1,201,101);load(3,5,3);
        shown_slot=0;#1;if(minfo[20:0]!=={10'd960,11'd1280}) $fatal(1,"FAIL meter slot 0");
        shown_slot=1;#1;if(minfo[20:0]!=={10'd101,11'd201}) $fatal(1,"FAIL meter slot 1");
        shown_slot=2;#1;if(minfo[20:0]!==0) $fatal(1,"FAIL meter unloaded slot");
        shown_slot=3;#1;if(minfo[20:0]!=={10'd3,11'd5}) $fatal(1,"FAIL meter slot 3");
        // Init time counts from reset, freezes when init_done rises and stays
        // frozen if init_done later falls (recovery re-initialization).
        wait(minfo[32:21]==37);@(negedge mclk);init_done=1;
        repeat(100) @(negedge mclk);
        if(minfo[32:21]!==37) $fatal(1,"FAIL meter init time %0d, expected 37",minfo[32:21]);
        init_done=0;repeat(100) @(negedge mclk);
        if(minfo[32:21]!==37) $fatal(1,"FAIL meter init time moved after init_done fell: %0d",minfo[32:21]);
        mrst=1;@(negedge mclk);mrst=0;
        if(minfo[32:21]!==0) $fatal(1,"FAIL meter init time not cleared by reset: %0d",minfo[32:21]);
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        // First-image time runs from reset and freezes once media_valid rises.
        wait(dut.load_centis==462);media_valid=1;
        repeat(20000) @(negedge clk);
        if(dut.load_centis!=462) $fatal(1,"FAIL load time not frozen: %0d",dut.load_centis);
        // No image yet: dashes, no zoom; load timer running.
        show(0,0,0,"BMP:   -X  - ZOOM:             ");
        show(1280,960,466,"BMP:1280X960 ZOOM:  0.50X  0.50");
        if(row_b[8*(30-22) +: 8*11]!=="INIT:04.66S") $fatal(1,"FAIL init text '%s'",row_b);
        show(640,480,0,"BMP: 640X480 ZOOM:  1.00X  1.00");
        if(row_b[8*(30-22) +: 8*11]!=="INIT:00.00S") $fatal(1,"FAIL zero init text '%s'",row_b);
        show(201,101,4095,"BMP: 201X101 ZOOM:  3.18X  4.75");
        if(row_b[8*(30-22) +: 8*11]!=="INIT:40.95S") $fatal(1,"FAIL max init text '%s'",row_b);
        show(5,3,1,"BMP:   5X  3 ZOOM:128.00X160.00");
        if(row_b[8*(30-22) +: 8*11]!=="INIT:00.01S") $fatal(1,"FAIL min init text '%s'",row_b);
        // Panel backdrop covers the new rows only.
        if(pixel_panel!==24'h2c5078 || pixel_below!==24'h4080c0) $fatal(1,"FAIL backdrop %h/%h",pixel_panel,pixel_below);
        if(row_b[8*(30-10) +: 8*11]!=="LOAD:04.62S") $fatal(1,"FAIL load text '%s'",row_b);
        // Menu mode and debug panel keep their original layout.
        settings=16'h8588;draw();draw();
        if(pixel_below!==24'h4080c0 || pixel_panel!==24'h4080c0) $fatal(1,"FAIL rows drawn in menu mode %h",pixel_panel);
        settings=16'h0588;diag[108]=1;draw();draw();
        if(row_a[8*29 +: 8*2]!=="L:") $fatal(1,"FAIL debug panel row replaced: '%s'",row_a);
        $display("PASS media_info: size/zoom rows (1280x960, 640x480, 201x101, 5x3, none), init time 00.00/00.01/04.66/40.95 s, load time frozen at 04.62, backdrop, menu/debug layouts preserved, SD meter init time and slots");
        $finish;
    end
    initial begin #80_000_000;$fatal(1,"FAIL media_info timeout");end
endmodule
