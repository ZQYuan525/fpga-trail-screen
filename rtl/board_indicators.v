`timescale 1ns/1ps
// LED0-3: auto play / image loading / HDMI audio nonzero / fault (active high).
// Passive buzzer behind a PNP: a low level conducts, so idle stays high and a
// beep is a TICK_HZ/2 square wave. Boot: short beep with all LEDs lit.
// Fault: one long beep once the fault has persisted, so a cold-card retry
// that recovers on its own stays quiet.
// LEDs are dimmed: lit for the first 1/LED_DUTY_DIV of every tone tick (4 kHz).
module board_indicators #(
    parameter integer CLK_HZ=50_000_000,LED_DUTY_DIV=4
)(
    input wire clk,rst,
    input wire auto_enabled,card_active,audio_active,fault,
    output reg [3:0] led,
    output reg buzzer_n
);
    localparam integer TICK_HZ=4000;
    localparam integer TICK=CLK_HZ/TICK_HZ;
    localparam integer BOOT_TICKS=TICK_HZ*3/20;   // 150 ms
    localparam integer FAULT_TICKS=TICK_HZ;       // 1 s beep
    localparam integer HOLD_TICKS=TICK_HZ;        // 1 s persistence
    localparam integer CARD_TICKS=TICK_HZ/20;     // 50 ms activity stretch
    localparam integer LED_ON=TICK/LED_DUTY_DIV;
    reg [$clog2(TICK)-1:0] prescale;
    reg tick,tone,booting,fault_beeped;
    reg [11:0] beep,hold;
    reg [7:0] card_hold;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            prescale<=0;tick<=0;tone<=0;booting<=1;fault_beeped<=0;
            beep<=BOOT_TICKS;hold<=0;card_hold<=0;led<=0;buzzer_n<=1;
        end else begin
            tick<=prescale==TICK-1;
            prescale<=prescale==TICK-1?0:prescale+1'b1;
            if(tick) tone<=~tone;
            if(card_active) card_hold<=CARD_TICKS;
            else if(tick && card_hold!=0) card_hold<=card_hold-1'b1;
            if(!fault) begin hold<=0;fault_beeped<=0;end
            else if(tick && hold!=HOLD_TICKS) hold<=hold+1'b1;
            if(fault && hold==HOLD_TICKS && !fault_beeped) begin beep<=FAULT_TICKS;fault_beeped<=1;booting<=0;end
            else if(tick && beep!=0) begin beep<=beep-1'b1;if(beep==1) booting<=0;end
            led<=(booting?4'hf:{fault,audio_active,card_hold!=0,auto_enabled}) & {4{prescale<LED_ON}};
            buzzer_n<=!(beep!=0 && tone);
        end
    end
endmodule
