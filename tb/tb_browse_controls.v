`timescale 1ns/1ps
module tb_browse_controls;
    reg clk=0,rst=1,k1=1,k2=1,busy=0;
    reg restore=0;reg [15:0] restored=0;
    wire [2:0] volume;wire [1:0] transition;
    reg [1:0] current=1;
    reg [3:0] available=4'b1010;
    always #5 clk=~clk;
    wire next_evt,auto_evt,prev_evt,view,pending,select_evt;
    wire [1:0] focus,index,viz;wire [15:0] settings;
    integer nexts=0,autos=0,prevs=0,selects=0;
    player_controls #(.ADVANCED(1),.PERSISTENCE(1),.EXTENDED_MENU(1),.CLK_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(8),.LONG_MS(16)) dut(
        .clk(clk),.rst(rst),.key1(k1),.key2(k2),.restore(restore),.restored(restored),
        .available(available),.current_image(current),.player_busy(busy),
        .next_event(next_evt),.auto_event(auto_evt),.prev_event(prev_evt),.settings(settings),.volume(volume),.transition_kind(transition),
        .view_mode(view),.confirm_pending(pending),.select_event(select_evt),.focus_index(focus),.select_index(index),.visualization(viz));
    always @(posedge clk) if(!rst) begin
        if(next_evt) nexts=nexts+1;if(auto_evt) autos=autos+1;if(prev_evt) prevs=prevs+1;if(select_evt) selects=selects+1;
    end
    task ticks(input integer n);begin repeat(n) @(negedge clk);end endtask
    task key(input integer which,duration);begin if(which==1) k1=0;else k2=0;ticks(duration);k1=1;k2=1;ticks(12);end endtask
    task chord;begin k1=0;k2=0;ticks(30);k1=1;ticks(3);k2=1;ticks(12);end endtask
    initial begin
        ticks(3);rst=0;ticks(4);
        key(1,8);key(2,8);if(nexts!=1 || autos!=1) $fatal(1,"normal actions");
        key(1,50);if(!view || focus!=1 || nexts!=1) $fatal(1,"long KEY2 entry/release leaked");
        key(1,8);if(focus!=2) $fatal(1,"focus navigation");
        key(2,8);if(!view || pending || selects) $fatal(1,"unloaded selection accepted");
        key(1,8);busy=1;key(2,8);
        if(!view || !pending || selects!=1 || index!=3) $fatal(1,"direct selection request");
        key(1,50);key(2,50);chord();
        if(!view || !pending || settings[15] || focus!=3 || selects!=1 || prevs || autos!=1) $fatal(1,"in-flight controls leaked");
        current=3;busy=0;ticks(4);if(view || pending) $fatal(1,"selection completion");
        key(1,50);key(2,50);if(view || prevs || autos!=1) $fatal(1,"cancel leaked previous/auto");
        key(1,50);key(2,8);if(view || selects!=1) $fatal(1,"same-image exit");
        chord();repeat(3) key(1,8);key(2,8);if(viz!=2 || !settings[6]) $fatal(1,"wave mode");
        key(2,8);if(viz!=0 || settings[6]) $fatal(1,"visualization off");
        key(2,8);if(viz!=1 || !settings[6]) $fatal(1,"FFT wrap");
        chord();key(2,50);if(prevs!=1) $fatal(1,"full-screen previous changed");
        restored=16'h0508;restore=1;ticks(1);restore=0;ticks(1);
        if(viz!=0 || settings[6]) $fatal(1,"legacy restore disabled visualization");
        restored=16'h0548;restore=1;ticks(1);restore=0;ticks(1);
        if(viz!=1 || !settings[6]) $fatal(1,"legacy restore enabled FFT");
        $display("PASS browse_controls: entry/cancel, incomplete slots, confirmation lock, same-image return, chord suppression, visualization cycle, legacy keys");$finish;
    end
    initial begin #100000;$fatal(1,"browse controls timeout");end
endmodule
