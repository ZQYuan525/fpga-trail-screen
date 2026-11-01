`timescale 1ns/1ps
// Same PCM/valid as HDMI. Freeze a complete capture before frame publication.
// Two LUT RAM banks: capture fills one while the other is shown; a complete
// capture swaps them at frame_start. rd_sample is the shown bank at the
// previous clock's rd_bin, 0 while !valid.
module audio_waveform #(
    parameter integer DECIMATE=12
)(
    input wire clk,rst,sample_valid,frame_start,
    input wire signed [23:0] sample,
    input wire [4:0] rd_bin,output wire [7:0] rd_sample,
    output reg [7:0] peak,
    output reg valid
);
    (* ram_style="dram" *) reg [7:0] capture[0:63];
    reg [7:0] capture_q;
    reg write_bank;
    reg [5:0] count;
    reg [7:0] spacing,window_peak;
    wire [23:0] magnitude=sample[23]?-sample:sample;
    // Include every sample, even after the waveform window has filled.
    wire [7:0] amplitude=magnitude[23:16];
    wire store=!frame_start && sample_valid && count<32 && spacing==0;
    assign rd_sample=valid?capture_q:8'd0;
    always @(posedge clk) begin
        if(store) capture[{write_bank,count[4:0]}]<=sample[23:16];
        capture_q<=capture[{!write_bank,rd_bin}];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            write_bank<=0;count<=0;spacing<=0;window_peak<=0;peak<=0;valid<=0;
        end else begin
            if(frame_start) begin
                if(count==32) begin write_bank<=!write_bank;valid<=1;end
                peak<=window_peak;
                count<=0;spacing<=0;window_peak<=sample_valid?amplitude:0;
            end else if(sample_valid) begin
                if(amplitude>window_peak) window_peak<=amplitude;
                if(count<32) begin
                    if(spacing==0) begin
                        count<=count+1'b1;spacing<=DECIMATE-1;
                    end else spacing<=spacing-1'b1;
                end
            end
        end
    end
endmodule
