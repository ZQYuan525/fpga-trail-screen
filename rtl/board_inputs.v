`timescale 1ns/1ps
// KEY3 (previous image) and SW1/SW2 stay outside player_controls: its
// two-key chord logic must never see a third key.
module board_inputs #(
    parameter integer CLK_HZ=100_000_000, DEBOUNCE_MS=20
)(
    input wire clk,rst,key3,
    input wire [1:0] sw,
    input wire allow_prev,
    output reg prev_event,
    output reg [1:0] switches
);
    localparam integer DB=(CLK_HZ/1000)*DEBOUNCE_MS;
    localparam integer W=$clog2(DB+1);
    (* async_reg="true" *) reg key_sync1,key_sync2;
    // Slide switches only need synchronizing; a bounce lasts far less than a frame.
    (* async_reg="true" *) reg [1:0] sw_sync;
    reg stable;
    reg [W-1:0] count;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            key_sync1<=1;key_sync2<=1;stable<=1;count<=0;prev_event<=0;sw_sync<=0;switches<=0;
        end else begin
            key_sync1<=key3;key_sync2<=key_sync1;
            sw_sync<=sw;switches<=sw_sync;
            prev_event<=0;
            if(key_sync2==stable) count<=0;
            else if(count>=DB-1) begin
                stable<=key_sync2;count<=0;
                // Active low: act on the debounced press edge.
                if(!key_sync2 && allow_prev) prev_event<=1;
            end else count<=count+1'b1;
        end
    end
endmodule
