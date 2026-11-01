`timescale 1ns/1ps
module tb_thumbnail_preview;
    reg sd=0,clk=0,rst=1,load=0,abort_load=0,write_pixel=0,top_down=1;
    always #5 sd=~sd;always #7 clk=~clk;
    reg [1:0] slot=0,focus=0;
    reg [23:0] wrgb=0;
    reg vs=0,de=0,view=0,pending=0;
    reg [4:0] gain=16;
    reg [3:0] complete=0,bad=0,catalog=15;
    wire ovs,ode,active;wire [23:0] rgb;
    thumbnail_preview dut(.sd_clk(sd),.sd_rst(rst),.load_start(load),.abort_load(abort_load),.write_pixel(write_pixel),
        .source_top_down(top_down),.write_slot(slot),.write_rgb(wrgb),.clk(clk),.rst(rst),
        .i_vs(vs),.i_de(de),.i_rgb(24'h123456),.view_mode(view),.confirm_pending(pending),.focus(focus),
        .complete(complete),.bad(bad),.catalog(catalog),.fade_gain(gain),.o_vs(ovs),.o_de(ode),.o_rgb(rgb),.active_view(active));
    function [23:0] source(input integer s,x,y);begin source={(8'(x)^8'(s*64)),8'(y),8'(x+y)};end endfunction
    function [23:0] quantize(input [23:0] c);begin quantize={{c[23:21],c[23:21],c[23:22]},{c[15:13],c[15:13],c[15:14]},{c[7:6],c[7:6],c[7:6],c[7:6]}};end endfunction
    integer s,x,y,n,phase=0,fd;
    integer ox,oy,id,lx,ly,src_y;
    reg [23:0] expected;
    reg in_window,is_border;
    always @(negedge clk) if(!rst && ode) begin
        ox=n%640;oy=n/640;
        in_window=((ox>=112 && ox<304)||(ox>=336 && ox<528)) && ((oy>=96 && oy<240)||(oy>=256 && oy<400));
        id=(oy>=256?2:0)+(ox>=336?1:0);
        lx=ox-(ox>=336?336:112);ly=oy-(oy>=256?256:96);
        is_border=lx<2 || lx>=190 || ly<2 || ly>=142;
        expected=24'h101820;
        if(phase==0 || phase==3 || phase==4) expected=24'h123456;
        else if(in_window) begin
            if(is_border) expected=id==0?24'hffcc40:24'h607080;
            else if(phase==2 && id==1) expected=(ox[3]^oy[3])?24'h605028:24'h302818;
            else if(phase==2 && id==2) expected=(ox[3]^oy[3])?24'h803030:24'h301818;
            else if(phase==2 && id==3) expected=24'h202830;
            else begin
                src_y=id[0]?(47-ly/3)*10:(ly/3)*10;
                expected=quantize(source(id,(lx/3)*10,src_y));
            end
        end
        if(rgb!==expected) $fatal(1,"preview raster phase=%0d x=%0d y=%0d got=%h expected=%h",phase,ox,oy,rgb,expected);
        if(phase==1) $fwrite(fd,"%06x\n",rgb);
        n=n+1;
    end
    task draw;
        begin
            @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(4) @(negedge clk);n=0;
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin
                    @(negedge clk);de=1;
                    if(phase==1 && y==150) begin focus=2;complete=0;view=0;end
                end
                @(negedge clk);de=0;repeat(4) @(negedge clk);
            end
            repeat(4) @(negedge clk);if(n!=307200) $fatal(1,"preview pixel count");
        end
    endtask
    initial begin
        repeat(4) @(negedge sd);rst=0;
        for(s=0;s<4;s=s+1) begin
            @(negedge sd);slot=s;top_down=!s[0];load=1;
            @(negedge sd);load=0;
            for(y=0;y<480;y=y+1) for(x=0;x<640;x=x+1) begin
                @(negedge sd);write_pixel=1;wrgb=source(s,x,y);
                if(x%67==0) begin @(negedge sd);write_pixel=0;@(negedge sd);end
            end
            @(negedge sd);write_pixel=0;
        end
        draw();complete=15;view=1;phase=1;fd=$fopen("thumbnail_frame.hex","w");draw();$fclose(fd);
        // Frame-level validity keeps changing masks/focus from tearing a frame.
        phase=2;view=1;focus=0;complete=1;bad=4;catalog=7;draw();
        // At the fade black boundary, commit the switch to full-screen.
        pending=1;gain=0;phase=3;draw();
        gain=16;phase=4;draw();if(active) $fatal(1,"pending confirmation reentered preview");
        $display("PASS thumbnail_preview: four slots, stalled capture, RGB332, both orientations, full raster, frame-stable masks/focus, placeholders, black-boundary exit");$finish;
    end
    initial begin #100000000;$fatal(1,"preview timeout");end
endmodule
