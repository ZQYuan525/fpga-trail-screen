`timescale 1ns/1ps
// Registered read port matches async_fifo; coordinates reset at frame request.
module diagnostic_pattern #(parameter WIDTH=640,HEIGHT=480)(
    input wire clk,rst,read_req,read_en,
    output reg read_ack,read_valid,
    output reg [23:0] read_data
);
    reg [9:0] x,y;
    reg [7:0] frame;
    always @(posedge clk or posedge rst) begin
        if(rst) begin x<=0;y<=0;frame<=0;read_ack<=0;read_valid<=0;read_data<=0;end
        else begin
            read_valid<=read_en;
            if(read_req && !read_ack) begin x<=0;y<=0;frame<=frame+1'b1;read_ack<=1;end
            if(!read_req) read_ack<=0;
            if(read_en) begin
                if(x==0 || x==WIDTH-1 || y==0 || y==HEIGHT-1) read_data<=24'hffffff;
                else read_data<={x[7:0],y[7:0],frame};
                if(x==WIDTH-1) begin x<=0;y<=y==HEIGHT-1?0:y+1'b1;end
                else x<=x+1'b1;
            end
        end
    end
endmodule
