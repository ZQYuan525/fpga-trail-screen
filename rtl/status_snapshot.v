`timescale 1ns/1ps
// Bundled data is held until acknowledgement; no independently synchronized bits.
module status_snapshot #(parameter WIDTH=4)(
    input wire src_clk,src_rst,input wire [WIDTH-1:0] value,
    input wire dst_clk,dst_rst,output reg [WIDTH-1:0] snapshot
);
    reg [WIDTH-1:0] held;
    reg request,acknowledge;
    (* async_reg="true" *) reg [2:0] ack_sync,request_sync;
    always @(posedge src_clk or posedge src_rst) begin
        if(src_rst) begin held<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[1:0],acknowledge};
            if(ack_sync[2]==request && value!=held) begin held<=value;request<=~request;end
        end
    end
    always @(posedge dst_clk or posedge dst_rst) begin
        if(dst_rst) begin request_sync<=0;acknowledge<=0;snapshot<=0;end
        else begin
            request_sync<={request_sync[1:0],request};
            if(request_sync[2]!=acknowledge) begin snapshot<=held;acknowledge<=request_sync[2];end
        end
    end
endmodule
