`timescale 1ns/1ps
module tb_extended_controls;
    wire [2:0] volume;wire [1:0] transition;
    reg clk=0,rst=1,key1=1,key2=1;always #5 clk=~clk;
    wire next_event,auto_event,prev_event;wire [15:0] settings;
    integer next_count=0,auto_count=0,prev_count=0;
    player_controls #(.EXTENDED_MENU(1),.CLK_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(8),.LONG_MS(12)) dut(
        .clk(clk),.rst(rst),.key1(key1),.key2(key2),.next_event(next_event),.auto_event(auto_event),.prev_event(prev_event),.settings(settings),.volume(volume),.transition_kind(transition));
    always @(posedge clk) if(!rst) begin
        if(next_event) next_count=next_count+1;
        if(auto_event) auto_count=auto_count+1;
        if(prev_event) prev_count=prev_count+1;
    end
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task short_key(input integer which);
        begin if(which==1) key1=0;else key2=0;tick(8);key1=1;key2=1;tick(8);end
    endtask
    task chord;
        begin key1=0;key2=0;tick(30);key1=1;tick(4);key2=1;tick(10);end
    endtask
    initial begin
        #23;rst=0;tick(3);
        key1=0;tick(1);key1=1;tick(8);if(next_count) $fatal(1,"debounce bounce");
        short_key(1);short_key(2);if(next_count!=1 || auto_count!=1) $fatal(1,"normal key routing");
        key2=0;tick(50);if(prev_count!=1 || auto_count!=1) $fatal(1,"long press repeated or short leaked");
        key2=1;tick(10);if(auto_count!=1) $fatal(1,"long release toggled auto");
        chord();if(prev_count!=1) $fatal(1,"chord leaked previous");if(!settings[15] || next_count!=1 || auto_count!=1) $fatal(1,"chord leaked actions/repeated toggle");
        short_key(2);if(settings[11:10]!=2) $fatal(1,"brightness edit");
        short_key(1);short_key(2);if(settings[14:12]!=1 || settings[9:8]!=2) $fatal(1,"contrast edit");
        short_key(1);short_key(2);if(settings[7]) $fatal(1,"OSD edit");
        short_key(1);short_key(2);if(settings[6]) $fatal(1,"spectrum edit");
        short_key(1);short_key(2);if(settings[5:4]!=1) $fatal(1,"period edit");
        short_key(2);short_key(2);short_key(2);if(settings[5:4]!=0) $fatal(1,"period wrap");
        short_key(1);short_key(2);if(settings[3]) $fatal(1,"source edit");
        short_key(1);if(settings[14:12]!=6 || volume!=4) $fatal(1,"volume menu entry");
        short_key(2);if(volume!=0) $fatal(1,"volume mute wrap");
        short_key(2);if(volume!=1) $fatal(1,"volume increment");
        short_key(1);if(settings[14:12]!=7) $fatal(1,"transition menu entry");
        short_key(2);if(transition!=1) $fatal(1,"transition increment");
        short_key(2);short_key(2);if(transition!=0) $fatal(1,"transition wrap");
        short_key(1);if(settings[14:12]!=0) $fatal(1,"eight item menu wrap");
        // Holding KEY2 inside the menu must not navigate pictures.
        key2=0;tick(50);key2=1;tick(10);if(prev_count!=1) $fatal(1,"menu hold navigated");
        chord();if(settings[15] || next_count!=1 || auto_count!=1) $fatal(1,"menu exit");
        short_key(1);if(next_count!=2) $fatal(1,"normal action after menu");
        $display("PASS extended_controls: volume mute/steps, transition selection, eight-item menu; synchronized debounce, release events, chord suppression, menu values and exit");$finish;
    end
    initial begin #100000;$fatal(1,"controls timeout");end
endmodule
