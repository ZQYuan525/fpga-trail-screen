`timescale 1ns/1ps
// Side capture of accepted scaler pixels. Display never reads a loading slot.
// Four 4096-byte slots (64x48 used), RGB332; full-screen RGB888 is untouched.
module thumbnail_preview(
    input wire sd_clk,sd_rst,load_start,abort_load,write_pixel,source_top_down,
    input wire [1:0] write_slot,input wire [23:0] write_rgb,
    input wire clk,rst,i_vs,i_de,input wire [23:0] i_rgb,
    input wire view_mode,confirm_pending,input wire [1:0] focus,
    input wire [3:0] complete,bad,catalog,input wire [4:0] fade_gain,
    output reg o_vs,o_de,output wire [23:0] o_rgb,
    output reg active_view
);
    reg [7:0] pixels[0:16383]; /* fehdl force_ram=1, ram_style="bram" */
    reg [9:0] wx;
    reg [3:0] dx,dy;
    reg [5:0] cx,cy;
    reg [1:0] slot;
    reg top_down,capturing;
    wire [5:0] row=top_down?cy:6'd47-cy;
    wire [13:0] write_address={slot,row,cx};
    always @(posedge sd_clk) begin
        if(capturing && write_pixel && !abort_load && dx==0 && dy==0)
            pixels[write_address]<={write_rgb[23:21],write_rgb[15:13],write_rgb[7:6]};
    end
    always @(posedge sd_clk or posedge sd_rst) begin
        if(sd_rst) begin wx<=0;dx<=0;dy<=0;cx<=0;cy<=0;slot<=0;top_down<=0;capturing<=0;end
        else if(abort_load) capturing<=0;
        else if(load_start) begin wx<=0;dx<=0;dy<=0;cx<=0;cy<=0;slot<=write_slot;top_down<=source_top_down;capturing<=1;end
        else if(capturing && write_pixel) begin
            if(wx==639) begin
                wx<=0;dx<=0;cx<=0;
                if(dy==9) begin dy<=0;if(cy==47) capturing<=0;else cy<=cy+1'b1;end
                else dy<=dy+1'b1;
            end else begin
                wx<=wx+1'b1;
                if(dx==9) begin dx<=0;cx<=cx+1'b1;end else dx<=dx+1'b1;
            end
        end
    end
    reg vs_q;
    reg [9:0] x,y;
    reg [5:0] col,line;
    reg [1:0] xr,yr;
    reg [3:0] ready_q,bad_q,catalog_q;
    reg [1:0] focus_q;
    wire frame_start=i_vs && !vs_q;
    wire in_x=(x>=112 && x<304)||(x>=336 && x<528);
    wire in_y=(y>=96 && y<240)||(y>=256 && y<400);
    wire [1:0] source={y>=256,x>=336};
    wire border=x==112 || x==113 || x==302 || x==303 || x==336 || x==337 || x==526 || x==527 ||
                y==96 || y==97 || y==238 || y==239 || y==256 || y==257 || y==398 || y==399;
    reg [7:0] pixel_q;
    reg [23:0] rgb_q;
    reg show_q,inside_q,border_q,ready_pixel,bad_pixel,catalog_pixel,focus_pixel,stripe;
    always @(posedge clk) pixel_q<=pixels[{source,line,col}];
    wire [23:0] expanded={{pixel_q[7:5],pixel_q[7:5],pixel_q[7:6]},
                          {pixel_q[4:2],pixel_q[4:2],pixel_q[4:3]},
                          {pixel_q[1:0],pixel_q[1:0],pixel_q[1:0],pixel_q[1:0]}};
    assign o_rgb=!o_de?24'd0:!show_q?rgb_q:!inside_q?24'h101820:
        border_q?(focus_pixel?24'hffcc40:24'h607080):
        ready_pixel?expanded:bad_pixel?(stripe?24'h803030:24'h301818):
        catalog_pixel?(stripe?24'h605028:24'h302818):24'h202830;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_q<=0;x<=0;y<=0;col<=0;line<=0;xr<=0;yr<=0;
            ready_q<=0;bad_q<=0;catalog_q<=0;focus_q<=0;active_view<=0;
            o_vs<=0;o_de<=0;rgb_q<=0;show_q<=0;inside_q<=0;border_q<=0;
            ready_pixel<=0;bad_pixel<=0;catalog_pixel<=0;focus_pixel<=0;stripe<=0;
        end else begin
            vs_q<=i_vs;o_vs<=i_vs;o_de<=i_de;rgb_q<=i_rgb;
            show_q<=active_view;inside_q<=in_x && in_y;border_q<=border;
            ready_pixel<=ready_q[source];bad_pixel<=bad_q[source];catalog_pixel<=catalog_q[source];
            focus_pixel<=source==focus_q;stripe<=x[3]^y[3];
            if(frame_start) begin
                x<=0;y<=0;col<=0;line<=0;xr<=0;yr<=0;
                ready_q<=complete;bad_q<=bad;catalog_q<=catalog;focus_q<=focus;
                // Confirm uses the existing fade: leave overview at black.
                if(!view_mode || (confirm_pending && fade_gain==0)) active_view<=0;
                else if(!confirm_pending) active_view<=1;
            end else if(i_de) begin
                if(in_x) begin
                    if(xr==2) begin xr<=0;col<=col+1'b1;end else xr<=xr+1'b1;
                end else begin xr<=0;col<=0;end
                if(x==639) begin
                    x<=0;y<=y==479?0:y+1'b1;xr<=0;col<=0;
                    if(in_y) begin
                        if(yr==2) begin yr<=0;line<=line+1'b1;end else yr<=yr+1'b1;
                    end else begin yr<=0;line<=0;end
                end else x<=x+1'b1;
            end
        end
    end
endmodule
