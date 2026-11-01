`timescale 1ns/1ps
module tb_frame_fade;
    reg cclk=0,pclk=0,rst=1,req=0,style=0,mack=0,vs=0;
    always #5 cclk=~cclk;
    always #17 pclk=~pclk;
    wire mreq,ack,breq,back;wire [4:0] gain,bgain;
    integer g,iteration;
    frame_fade dut(.ctrl_clk(cclk),.ctrl_rst(rst),.pix_clk(pclk),.pix_rst(rst),
        .publish_req(req),.publish_fade(style),.memory_ack(mack),
        .memory_req(mreq),.publish_ack(ack),.i_vs(vs),.fade_gain(gain));
    frame_fade #(.ENABLED(0)) bypass(.ctrl_clk(cclk),.ctrl_rst(rst),.pix_clk(pclk),.pix_rst(rst),
        .publish_req(req),.publish_fade(style),.memory_ack(mack),
        .memory_req(breq),.publish_ack(back),.i_vs(vs),.fade_gain(bgain));
    always @(negedge cclk) begin
        if(breq!==req || back!==mack || bgain!==16) $fatal(1,"disabled bypass changed contract");
        if(!rst && req && style && mreq && !mack && gain!=0) $fatal(1,"reader request before black");
        if(!rst && req && style && ack && gain!=16) $fatal(1,"source released before fade-in finished");
    end
    task pixels(input integer expected);
        begin
            repeat(8) begin @(negedge pclk);
                if(gain!==expected) $fatal(1,"gain changed away from frame edge got=%0d want=%0d",gain,expected);
            end
        end
    endtask
    task frame(input integer expected);
        begin
            @(negedge pclk);vs=1;repeat(4) @(negedge pclk);vs=0;
            pixels(expected);
        end
    endtask
    task reset_all;
        begin
            #3;rst=1;req=0;mack=0;vs=0;
            repeat(5) @(negedge pclk);rst=0;pixels(16);
            if(ack || mreq) $fatal(1,"reset did not clear handshake");
        end
    endtask
    task start_manual;
        begin @(negedge cclk);style=1;req=1;pixels(16);end
    endtask
    task fade_out;
        begin for(g=15;g>=0;g=g-1) frame(g);end
    endtask
    task release_all;
        begin
            wait(ack);@(negedge cclk);req=0;
            repeat(12) @(negedge pclk);
            if(!ack || mreq) $fatal(1,"ack must wait for reader return-to-zero");
            mack=0;wait(!ack);pixels(16);
        end
    endtask
    initial begin
        reset_all();
        // Startup and automatic publication: reader owns duration; no fade.
        style=0;req=1;#1;if(!mreq) $fatal(1,"automatic request stalled");
        frame(16);if(ack) $fatal(1,"ack without reader adoption");
        mack=1;wait(ack);release_all();
        // Repeated transactions without reset exercise all four return phases.
        for(iteration=0;iteration<5;iteration=iteration+1) begin
            #(iteration*7+1);start_manual();fade_out();
            if(!mreq || ack) $fatal(1,"black grant/source ownership");
            frame(0);frame(0); // reader may be arbitrarily late
            @(negedge cclk);mack=1;pixels(0);
            for(g=1;g<=16;g=g+1) frame(g);
            release_all();
        end
        // Common reset during every phase must restore the initial image gain.
        start_manual();frame(15);reset_all();
        start_manual();fade_out();reset_all();
        start_manual();fade_out();mack=1;pixels(0);frame(1);reset_all();
        start_manual();fade_out();mack=1;pixels(0);
        for(g=1;g<=16;g=g+1) frame(g);
        wait(ack);reset_all();
        $display("PASS frame_fade: asynchronous handshake, 16+16 steps, delayed adoption, repeated requests, reset in every phase, disabled/automatic bypass");
        $finish;
    end
    initial begin #1000000;$fatal(1,"frame fade watchdog");end
endmodule
