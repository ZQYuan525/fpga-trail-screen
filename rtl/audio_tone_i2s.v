`timescale 1ns/1ps
// Legacy module name; actual interface is parallel signed PCM for the HDMI core.
// Fractional sample enable in the pixel domain avoids an inaccurate audio PLL.
module audio_tone_i2s #(
    parameter integer CLK_FREQ_HZ=25_000_000, ENABLE_MEDIA=0
)(
    input wire clk,rst,
    input wire media_mode,media_valid,input wire [1:0] media_index,
    output reg audio_valid,
    output reg [23:0] audio_left,audio_right,
    output reg acr_valid,
    output wire [19:0] acr_cts,acr_n
);
    localparam integer SAMPLE_RATE=48_000;
    reg [31:0] sample_acc;
    reg [5:0] sample_count;
    reg [7:0] phase_acc;
    wire [5:0] phase=phase_acc[7:2];
    reg active_mode,active_valid;
    reg [1:0] active_index;
    reg [6:0] gain;
    wire desired_mode=ENABLE_MEDIA?media_mode:1'b0;
    wire desired_valid=desired_mode?media_valid:1'b1;
    wire [1:0] desired_index=desired_mode?media_index:2'd0;
    wire changing=desired_mode!=active_mode || desired_valid!=active_valid || desired_index!=active_index;
    wire [7:0] phase_step=!active_mode?8'd4:active_index==0?8'd2:active_index==1?8'd3:active_index==2?8'd4:8'd6;
    wire [8:0] next_phase={1'b0,phase_acc}+phase_step;
    reg [23:0] tone;
    wire signed [31:0] scaled_tone=$signed(tone)*$signed({1'b0,gain});
    wire [23:0] output_tone=ENABLE_MEDIA?(active_valid?(scaled_tone>>>6):24'd0):tone;
    assign acr_n=20'd6144;
    assign acr_cts=CLK_FREQ_HZ/1000;
    always @(*) begin
        case(phase)
            0:tone=24'sd0;1:tone=24'sd136867;2:tone=24'sd271391;3:tone=24'sd401272;
            4:tone=24'sd524287;5:tone=24'sd638332;6:tone=24'sd741454;7:tone=24'sd831890;
            8:tone=24'sd908093;9:tone=24'sd968757;10:tone=24'sd1012846;11:tone=24'sd1039604;
            12:tone=24'sd1048575;13:tone=24'sd1039604;14:tone=24'sd1012846;15:tone=24'sd968757;
            16:tone=24'sd908093;17:tone=24'sd831890;18:tone=24'sd741454;19:tone=24'sd638332;
            20:tone=24'sd524287;21:tone=24'sd401272;22:tone=24'sd271391;23:tone=24'sd136867;
            24:tone=24'sd0;25:tone=-24'sd136867;26:tone=-24'sd271391;27:tone=-24'sd401272;
            28:tone=-24'sd524287;29:tone=-24'sd638332;30:tone=-24'sd741454;31:tone=-24'sd831890;
            32:tone=-24'sd908093;33:tone=-24'sd968757;34:tone=-24'sd1012846;35:tone=-24'sd1039604;
            36:tone=-24'sd1048575;37:tone=-24'sd1039604;38:tone=-24'sd1012846;39:tone=-24'sd968757;
            40:tone=-24'sd908093;41:tone=-24'sd831890;42:tone=-24'sd741454;43:tone=-24'sd638332;
            44:tone=-24'sd524288;45:tone=-24'sd401272;46:tone=-24'sd271391;47:tone=-24'sd136867;
            default:tone=0;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            sample_acc<=0;phase_acc<=0;sample_count<=0;audio_valid<=0;acr_valid<=0;
            active_mode<=0;active_valid<=1;active_index<=0;gain<=ENABLE_MEDIA?0:64;
            audio_left<=0;audio_right<=0;
        end else begin
            audio_valid<=0;acr_valid<=0;
            if(sample_acc>=CLK_FREQ_HZ-SAMPLE_RATE) begin
                sample_acc<=sample_acc+SAMPLE_RATE-CLK_FREQ_HZ;
                phase_acc<=next_phase>=192?next_phase-192:next_phase;
                // Ramp down before switching phase/frequency, then ramp up.
                // Neither PCM enables nor ACR cadence pause during a transition.
                if(ENABLE_MEDIA) begin
                    if(changing) begin
                        if(gain!=0) gain<=gain-1'b1;
                        else begin
                            active_mode<=desired_mode;active_valid<=desired_valid;
                            active_index<=desired_index;phase_acc<=0;
                        end
                    end else if(active_valid && gain<64) gain<=gain+1'b1;
                end
                audio_valid<=1;audio_left<=output_tone;audio_right<=output_tone;
                if(sample_count==47) begin sample_count<=0;acr_valid<=1;end
                else sample_count<=sample_count+1'b1;
            end else sample_acc<=sample_acc+SAMPLE_RATE;
        end
    end
endmodule
