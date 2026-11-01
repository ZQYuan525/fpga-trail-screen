`timescale 1ns/1ps
// Passive SD-domain first-fault capture. No feedback to the media datapath.
module board_diagnostics(
    input wire clk,rst,
    input wire [3:0] status_code,init_error,bmp_state,
    input wire [2:0] found_total,
    input wire [15:0] flags,
    input wire [11:0] read_diagnostic,
    input wire sector_req,sector_valid,sector_error,load_start,pixel_accept,
    input wire [31:0] sector_addr,
    input wire [7:0] sector_data,
    output reg [108:0] report
);
    reg frozen,sector_error_seen;
    reg [3:0] last_bmp_state;
    reg [1:0] header_bytes;
    reg [15:0] signature;
    reg [19:0] pixels;
    reg capture_pending;
    reg [107:0] capture_payload;
    wire [15:0] captured_flags=flags | ((sector_error_seen || sector_error)?16'h1000:16'd0);
    // Sample the entire payload on the same edge as the first-fault decision.
    // Publish it one edge later, so the top's status priority encoder does not
    // also drive 109 report-register enables in the same 100 MHz cycle.
    always @(posedge clk or posedge rst) begin
        if(rst) begin capture_pending<=0;capture_payload<=0;report<=0;end
        else begin
            capture_payload<={read_diagnostic,init_error,last_bmp_state,1'b0,found_total,
                              captured_flags,sector_addr,signature,pixels};
            capture_pending<=!frozen && status_code>=4'ha;
            if(capture_pending) report<={1'b1,capture_payload};
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            frozen<=0;sector_error_seen<=0;last_bmp_state<=0;
            header_bytes<=0;signature<=0;pixels<=0;
        end else if(!frozen) begin
            if(sector_error) sector_error_seen<=1;
            if(bmp_state<4'ha) last_bmp_state<=bmp_state;
            if(sector_req && sector_addr==0) begin header_bytes<=0;signature<=0;end
            else if(sector_valid && sector_addr==0 && header_bytes<2) begin
                if(header_bytes==0) signature[7:0]<=sector_data;
                else signature[15:8]<=sector_data;
                header_bytes<=header_bytes+1'b1;
            end
            if(load_start) pixels<=0;
            else if(pixel_accept && pixels!=20'hfffff) pixels<=pixels+1'b1;
            // Last non-error BMP phase survives the decoder returning to IDLE.
            if(status_code>=4'ha) begin
                frozen<=1;
            end
        end
    end
endmodule
