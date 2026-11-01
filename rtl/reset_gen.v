`timescale 1ns/1ps
// PLL outputs are synchronized before the startup stability interval.
// Common reset request is released separately in every destination domain.
module reset_gen #(parameter integer LOCK_STABLE_CYCLES=1_000_000)(
    input wire clk,rst_n,sys_pll_lock,video_pll_lock,
    output reg rst_all
);
    (* async_reg="true" *) reg [1:0] sys_lock,video_lock;
    localparam CW=$clog2(LOCK_STABLE_CYCLES+1);
    reg [CW-1:0] count;
    reg released;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sys_lock<=0;video_lock<=0;count<=0;released<=0;rst_all<=1;
        end else begin
            sys_lock<={sys_lock[0],sys_pll_lock};video_lock<={video_lock[0],video_pll_lock};
            if(!released) begin
                if(sys_lock[1] && video_lock[1]) begin
                    if(count==LOCK_STABLE_CYCLES-1) begin released<=1;rst_all<=0;end
                    else count<=count+1'b1;
                end else count<=0;
            end
        end
    end
endmodule
