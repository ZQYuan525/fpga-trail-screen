`timescale 1ns/1ps
// Switch only at zero gain; valid and ACR remain continuous through the fade.
module audio_source_mux(
    input wire clk,rst,sample_valid,acr_in,select_wav,
    input wire signed [23:0] tone_left,tone_right,wav_left,wav_right,
    output reg valid,acr_out,
    output reg signed [23:0] left,right
);
    reg active;
    reg [6:0] gain;
    wire signed [23:0] source_left=active?wav_left:tone_left;
    wire signed [23:0] source_right=active?wav_right:tone_right;
    wire signed [31:0] scaled_left=source_left*$signed({1'b0,gain});
    wire signed [31:0] scaled_right=source_right*$signed({1'b0,gain});
    always @(posedge clk or posedge rst) begin
        if(rst) begin active<=0;gain<=64;valid<=0;acr_out<=0;left<=0;right<=0;end
        else begin
            valid<=sample_valid;acr_out<=acr_in;
            if(sample_valid) begin
                left<=scaled_left>>>6;right<=scaled_right>>>6;
                if(active!=select_wav) begin
                    if(gain!=0) gain<=gain-1'b1;
                    else active<=select_wav;
                end else if(gain<64) gain<=gain+1'b1;
            end
        end
    end
endmodule
