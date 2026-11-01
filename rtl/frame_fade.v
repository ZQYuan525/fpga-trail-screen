`timescale 1ns/1ps
// Fade a READY publication, not an unaccepted key pulse.
// A four-phase level handshake holds the target until fade-in finishes. This
// preserves sd_player's newest-pending-direction queue and reader ownership.
module frame_fade #(parameter integer ENABLED=1)(
    input wire ctrl_clk,ctrl_rst,pix_clk,pix_rst,
    input wire publish_req,publish_fade,memory_ack,
    output wire memory_req,output wire publish_ack,
    input wire i_vs,output wire [4:0] fade_gain
);
    generate if(!ENABLED) begin: g_bypass
        assign memory_req=publish_req;
        assign publish_ack=memory_ack;
        assign fade_gain=5'd16;
    end else begin: g_fade
        localparam IDLE=0,OUT=1,HOLD=2,IN=3,DONE=4;
        reg [2:0] state;
        reg [4:0] gain;
        assign fade_gain=gain;
        reg grant,complete,ack_held,vs_d;
        (* async_reg="true" *) reg [2:0] request_sync,adopt_sync;
        (* async_reg="true" *) reg [2:0] grant_sync,complete_sync,ack_sync;
        wire request=publish_req && publish_fade;
        wire frame_start=i_vs && !vs_d;
        assign memory_req=publish_req && (!publish_fade || grant_sync[2]);
        assign publish_ack=ack_held;
        always @(posedge ctrl_clk or posedge ctrl_rst) begin
            if(ctrl_rst) begin grant_sync<=0;complete_sync<=0;ack_sync<=0;ack_held<=0;end
            else begin
                grant_sync<={grant_sync[1:0],grant};
                complete_sync<={complete_sync[1:0],complete};
                ack_sync<={ack_sync[1:0],memory_ack};
                if(publish_req && ack_sync[2] && (!publish_fade || complete_sync[2])) ack_held<=1;
                // Do not release the source for its next queued request until
                // BOTH the reader and the pixel-domain handshake return low.
                if(!publish_req && !ack_sync[2] && !complete_sync[2]) ack_held<=0;
            end
        end
        always @(posedge pix_clk or posedge pix_rst) begin
            if(pix_rst) begin
                request_sync<=0;adopt_sync<=0;vs_d<=0;
                state<=IDLE;gain<=16;grant<=0;complete<=0;
            end else begin
                request_sync<={request_sync[1:0],request};
                adopt_sync<={adopt_sync[1:0],memory_ack};
                vs_d<=i_vs;
                case(state)
                    IDLE: if(request_sync[2] && frame_start) begin gain<=15;state<=OUT;end
                    OUT: if(frame_start) begin
                        gain<=gain-1'b1;
                        if(gain==1) begin grant<=1;state<=HOLD;end
                    end
                    HOLD: if(frame_start && adopt_sync[2]) begin gain<=1;state<=IN;end
                    IN: if(frame_start) begin
                        gain<=gain+1'b1;
                        if(gain==15) begin complete<=1;state<=DONE;end
                    end
                    DONE: if(!request_sync[2]) begin grant<=0;complete<=0;state<=IDLE;end
                    default: begin state<=IDLE;gain<=16;grant<=0;complete<=0;end
                endcase
            end
        end
        // video_overlay applies gain AFTER brightness/contrast and BEFORE
        // OSD. Scaling earlier would turn black back to gray at brightness +32.
    end endgenerate
endmodule
