`timescale 1ns/1ps
// read_ack is already synchronized to VIDEO. Its bundled metadata was latched
// in MEM before FIFO reset/release and stays stable through the frame request.
module frame_media_status(
    input wire clk,rst,read_ack,i_vs,i_de,display_enable,
    input wire [1:0] memory_image,
    output reg [1:0] image_index,output reg image_valid
);
    reg ack_d,vs_d,await_pixel;
    reg [1:0] pending_image;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            ack_d<=0;vs_d<=0;await_pixel<=1;pending_image<=0;image_index<=0;image_valid<=0;
        end else begin
            ack_d<=read_ack;vs_d<=i_vs;
            if(read_ack && !ack_d) pending_image<=memory_image;
            if(i_vs && !vs_d) await_pixel<=1;
            if(await_pixel && i_de) begin
                image_index<=pending_image;image_valid<=display_enable;await_pixel<=0;
            end
        end
    end
endmodule
