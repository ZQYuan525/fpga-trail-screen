`timescale 1ns/1ps
// SD-domain auto-recovery for a failed image load (observed: cold card
// power-up returns 0xFF token data at 16.67 MHz). For load failures the
// player's own abort handshake cleans decoder/scaler/write side, and once it
// has settled we request a retry of the same image (active-low pulse retained
// for the recovery event adapter). MAX_ATTEMPTS tries, new-load success
// clears the budget; exhaustion goes sticky DEAD until rst_sd. Init failures
// instead pulse src_rst for init/sector/SPI only; the retry budget survives.
module media_recovery #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer MAX_ATTEMPTS=3,
    parameter integer ABORT_TIME_CYCLES=CLK_FREQ_HZ/5,       // 200 ms abort settle
    parameter integer PRESS_TIME_CYCLES=CLK_FREQ_HZ/40,      // 25 ms key press
    parameter integer INIT_HOLD_CYCLES=CLK_FREQ_HZ/1000,     // 1 ms source reset
    parameter integer SESSION_WINDOW_CYCLES=CLK_FREQ_HZ*30   // 30 s to display (covers 1280x960 at 2 MHz)
)(
    input wire clk,rst,
    input wire media_error,      // player error level (sticky until next load)
    input wire init_error,       // SD init sequence failed (sticky err_code)
    input wire display_valid,    // player published an image
    input wire load_success,     // pulse only when a NEW complete frame is adopted
    input wire progress,         // scan/load progress keeps the inactivity timer alive
    output reg key_retry,        // synthetic key: low = pressed, release triggers
    output reg src_rst,          // reset for the SD source side (init/sector/spi)
    output reg [1:0] attempts,   // retries consumed since last success
    output reg failed            // gave up; sticky until rst_sd
);
    localparam BOOTW=0,IDLE=1,WAIT_ABORT=2,PRESS=3,WATCH=4,INIT_WAIT=5,INIT_HOLD=6,DEAD=7;
    reg [2:0] state;
    reg [31:0] ticks;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=BOOTW;ticks<=0;key_retry<=1;src_rst<=0;attempts<=0;failed<=0;
        end else begin
            case(state)
                BOOTW: begin
                    failed<=0;
                    if(init_error) begin
                        // init sequence failed: re-run it after a settle window
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD; end
                        else begin ticks<=0;attempts<=attempts+1;state<=INIT_WAIT; end
                    end else if(load_success || (display_valid && !media_error && attempts==0)) begin attempts<=0;state<=IDLE;end
                    else if(media_error || (ticks>=SESSION_WINDOW_CYCLES && !progress)) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD; end
                        else begin ticks<=0;attempts<=attempts+1;state<=WAIT_ABORT; end
                    end else if(progress) ticks<=0;
                    else ticks<=ticks+1;
                end
                INIT_WAIT: if(ticks>=ABORT_TIME_CYCLES-1) begin
                    src_rst<=1;ticks<=0;state<=INIT_HOLD;
                end else ticks<=ticks+1;
                INIT_HOLD: if(ticks>=INIT_HOLD_CYCLES-1) begin
                    src_rst<=0;ticks<=0;state<=BOOTW;   // init re-runs; err_code cleared
                end else ticks<=ticks+1;
                IDLE: begin
                    failed<=0;
                    if(load_success) attempts<=0;
                    if(init_error) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD;end
                        else begin ticks<=0;attempts<=attempts+1;state<=INIT_WAIT;end
                    end else if(media_error) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD; end
                        else begin ticks<=0;attempts<=attempts+1;state<=WAIT_ABORT; end
                    end
                end
                WAIT_ABORT: if(ticks>=ABORT_TIME_CYCLES-1) begin
                    key_retry<=0;ticks<=0;state<=PRESS;   // press the key
                end else ticks<=ticks+1;
                PRESS: if(ticks>=PRESS_TIME_CYCLES-1) begin
                    key_retry<=1;ticks<=0;state<=WATCH;   // release triggers the load
                end else ticks<=ticks+1;
                WATCH: begin
                    if(load_success) begin attempts<=0;state<=IDLE; end
                    else if(init_error) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD;end
                        else begin ticks<=0;attempts<=attempts+1;state<=INIT_WAIT;end
                    end
                    else if(media_error && ticks>CLK_FREQ_HZ/10) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD; end
                        else begin ticks<=0;attempts<=attempts+1;state<=WAIT_ABORT; end
                    end else if(ticks>=SESSION_WINDOW_CYCLES && !progress) begin
                        if(attempts>=MAX_ATTEMPTS) begin failed<=1;state<=DEAD; end
                        else begin ticks<=0;attempts<=attempts+1;state<=WAIT_ABORT; end
                    end else if(progress) ticks<=0;
                    else ticks<=ticks+1;
                end
                DEAD: state<=DEAD;  // sticky until rst_sd (manual reset/power cycle)
                default: state<=BOOTW;
            endcase
        end
    end
endmodule
