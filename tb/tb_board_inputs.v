`timescale 1ns/1ps
module tb_board_inputs;
    reg clk=0,rst=1,key3=1,allow=1;
    reg [1:0] sw=0;
    always #5 clk=~clk;
    wire prev;
    wire [1:0] switches;
    // DB = 1000 cycles.
    board_inputs #(.CLK_HZ(1_000_000),.DEBOUNCE_MS(1)) dut(.clk(clk),.rst(rst),.key3(key3),.sw(sw),
        .allow_prev(allow),.prev_event(prev),.switches(switches));
    integer pulses;
    always @(posedge clk) if(prev) pulses=pulses+1;
    task hold(input level,input integer cycles);
        begin key3=level;repeat(cycles) @(negedge clk);end
    endtask
    initial begin
        pulses=0;
        repeat(3) @(negedge clk);rst=0;
        hold(1,2000);
        if(pulses!=0) $fatal(1,"event while idle");
        // Bounces shorter than the debounce interval are ignored.
        repeat(5) begin hold(0,300);hold(1,300);end
        hold(1,2000);
        if(pulses!=0) $fatal(1,"bounce leaked %0d events",pulses);
        // One clean press: exactly one single-cycle event, on the press edge.
        hold(0,990);
        if(pulses!=0) $fatal(1,"event before debounce elapsed");
        hold(0,20);
        if(pulses!=1) $fatal(1,"press gave %0d events",pulses);
        hold(0,5000);
        hold(1,2000);
        if(pulses!=1) $fatal(1,"hold/release gave %0d events",pulses);
        // Menu or browse mode blocks KEY3.
        allow=0;hold(0,2000);hold(1,2000);
        if(pulses!=1) $fatal(1,"blocked press leaked");
        allow=1;hold(0,2000);hold(1,2000);
        if(pulses!=2) $fatal(1,"second press gave %0d total",pulses);
        // Switches: two-stage synchronizer, no debounce.
        sw=2'b01;@(negedge clk);
        if(switches!==2'b00) $fatal(1,"switch passed in one stage");
        @(negedge clk);
        if(switches!==2'b01) $fatal(1,"switch not after two stages");
        sw=2'b10;repeat(2) @(negedge clk);
        if(switches!==2'b10) $fatal(1,"switch 2 wrong");
        $display("PASS board_inputs: KEY3 debounced press edge, bounce rejected, menu/browse block, 2-stage switch sync");
        $finish;
    end
    initial begin #1000000;$fatal(1,"board_inputs watchdog");end
endmodule
