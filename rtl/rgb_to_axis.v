`timescale 1ns/1ps
// Video stream FIFO: tags follow pixels, output holds stable under backpressure.
// Overflow discards input until a VS boundary with a drained queue, then resyncs.
module rgb_to_axis #(parameter WIDTH=640,HEIGHT=480,DEPTH=32)(
    input wire clk,rst,i_vs,i_de,
    input wire [23:0] i_rgb,
    input wire i_ready,
    output wire o_user,o_valid,o_last,
    output wire [23:0] o_data,
    output reg overflow
);
    localparam AW=$clog2(DEPTH);
    reg [25:0] queue[0:DEPTH-1];
    reg [AW-1:0] wr_ptr,rd_ptr;
    reg [AW:0] count;
    reg [15:0] x;
    reg vs_d,sof_pending,dropping;
    wire pop=count!=0 && i_ready;
    wire room=count<DEPTH || pop;
    wire push=i_de && !dropping && room;
    assign o_valid=count!=0;
    assign {o_user,o_last,o_data}=queue[rd_ptr];
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            wr_ptr<=0;rd_ptr<=0;count<=0;x<=0;vs_d<=0;
            sof_pending<=1;dropping<=0;overflow<=0;
        end else begin
            vs_d<=i_vs;
            if(i_vs && !vs_d) begin
                sof_pending<=1;x<=0;
                if(count==0) dropping<=0;
            end
            if(!i_de) x<=0;
            else x<=x==WIDTH-1?0:x+1'b1;
            if(i_de && !dropping && !room) begin overflow<=1;dropping<=1;end
            if(push) begin
                queue[wr_ptr]<={sof_pending,x==WIDTH-1,i_rgb};
                sof_pending<=0;wr_ptr<=wr_ptr+1'b1;
            end
            if(pop) rd_ptr<=rd_ptr+1'b1;
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
            endcase
        end
    end
endmodule
