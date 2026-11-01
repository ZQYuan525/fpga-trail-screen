`timescale 1ns/1ps
// Asynchronous assertion, synchronous release in the destination clock.
module reset_sync(input wire clk,arst,output wire rst);
    (* async_reg="true" *) reg [2:0] release_pipe;
    always @(posedge clk or posedge arst)
        if(arst) release_pipe<=3'b111;
        else release_pipe<={release_pipe[1:0],1'b0};
    assign rst=release_pipe[2];
endmodule
