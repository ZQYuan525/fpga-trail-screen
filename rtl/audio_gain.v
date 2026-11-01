`timescale 1ns/1ps
// Five volume levels; move gain by one of 64 units per PCM sample.
module audio_gain(
    input wire clk,rst,valid_in,acr_in,
    input wire [2:0] volume,
    input wire signed [23:0] left_in,right_in,
    output reg valid_out,acr_out,
    output reg signed [23:0] left_out,right_out
);
    reg [6:0] gain;
    wire [6:0] target=volume>=4?7'd64:{volume,4'b0};
    wire signed [31:0] l=left_in*$signed({1'b0,gain});
    wire signed [31:0] r=right_in*$signed({1'b0,gain});
    always @(posedge clk or posedge rst) begin
        if(rst) begin gain<=64;valid_out<=0;acr_out<=0;left_out<=0;right_out<=0;end
        else begin
            valid_out<=valid_in;acr_out<=acr_in;
            if(valid_in) begin
                left_out<=l>>>6;right_out<=r>>>6;
                if(gain<target) gain<=gain+1'b1;
                else if(gain>target) gain<=gain-1'b1;
            end
        end
    end
endmodule
