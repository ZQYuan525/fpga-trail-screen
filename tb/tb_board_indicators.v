`timescale 1ns/1ps
module tb_board_indicators;
    reg clk=0,rst=1;
    reg auto=0,card=0,audio=0,fault=0;
    always #5 clk=~clk;
    wire [3:0] led;
    wire buzzer_n;
    // TICK = 10 cycles: boot 600 ticks, fault hold 4000 ticks, beep 4000 ticks, card 200 ticks.
    // LEDs are PWM-dimmed: on for TICK/4 = 2 of every 10 cycles, so lit LEDs are read over one tick.
    board_indicators #(.CLK_HZ(40_000)) dut(.clk(clk),.rst(rst),.auto_enabled(auto),.card_active(card),
        .audio_active(audio),.fault(fault),.led(led),.buzzer_n(buzzer_n));
    integer lows,edges,cycle,on,k;
    reg [3:0] lit;
    reg last_buzzer;
    task watch(input integer cycles);
        begin
            lows=0;edges=0;
            for(cycle=0;cycle<cycles;cycle=cycle+1) begin
                @(negedge clk);
                if(!buzzer_n) lows=lows+1;
                if(buzzer_n!==last_buzzer) edges=edges+1;
                last_buzzer=buzzer_n;
            end
        end
    endtask
    task lamp;
        begin
            lit=0;on=0;
            for(k=0;k<10;k=k+1) begin
                @(negedge clk);
                lit=lit|led;
                if(led!=0) on=on+1;
            end
        end
    endtask
    initial begin
        last_buzzer=1;
        @(negedge clk);
        if(buzzer_n!==1 || led!==0) $fatal(1,"reset outputs");
        rst=0;
        // Boot: all LEDs lit, square-wave beep for 150 ms (6000 cycles), then quiet.
        repeat(5) @(negedge clk);
        lamp;
        if(lit!==4'hf || on!=2) $fatal(1,"boot lamp test lit=%b on=%0d",lit,on);
        watch(5900);
        if(lows<2800 || lows>3100 || edges<550) $fatal(1,"boot beep lows=%0d edges=%0d",lows,edges);
        watch(300);
        if(led!==4'b0000) $fatal(1,"boot lamp test did not end led=%b",led);
        watch(20000);
        if(lows!=0) $fatal(1,"buzzer active while idle");
        // LEDs follow sources; card activity is stretched by 50 ms.
        auto=1;audio=1;repeat(3) @(negedge clk);
        lamp;
        if(lit!==4'b0101 || on!=2) $fatal(1,"auto/audio lit=%b on=%0d",lit,on);
        card=1;repeat(3) @(negedge clk);card=0;
        repeat(1890) @(negedge clk);
        lamp;
        if(lit[1]!==1) $fatal(1,"card stretch too short");
        repeat(200) @(negedge clk);
        if(led[1]!==0) $fatal(1,"card stretch too long");
        auto=0;audio=0;
        // A fault shorter than 1 s lights LED3 but stays quiet.
        fault=1;repeat(3) @(negedge clk);
        lamp;
        if(lit!==4'b1000) $fatal(1,"fault lit=%b",lit);
        watch(39000);
        fault=0;
        if(lows!=0) $fatal(1,"short fault beeped");
        repeat(3) @(negedge clk);
        if(led!==0) $fatal(1,"fault led did not clear");
        // A persistent fault beeps once for 1 s (40000 cycles), not repeatedly.
        fault=1;
        watch(39000);
        if(lows!=0) $fatal(1,"fault beeped before 1 s");
        watch(42000);
        if(lows<19000 || lows>21000) $fatal(1,"fault beep lows=%0d",lows);
        watch(80000);
        if(lows!=0) $fatal(1,"fault beep repeated");
        // Clearing and re-entering the fault re-arms it.
        fault=0;repeat(3) @(negedge clk);fault=1;
        watch(81000);
        if(lows<19000 || lows>21000) $fatal(1,"re-armed fault beep lows=%0d",lows);
        $display("PASS board_indicators: boot lamp test + beep, LED mapping at TICK/4 PWM duty, card stretch, fault beep after 1 s persistence once, re-arm");
        $finish;
    end
    initial begin #5000000;$fatal(1,"board_indicators watchdog");end
endmodule
