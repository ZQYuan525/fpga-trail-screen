`timescale 1ns/1ps
// Fixed-size, uncompressed 24-bit bottom-up BMP reader over contiguous sectors.
// A sector is staged before parsing/emitting, so SD cannot overrun pixel backpressure.
module bmp_decoder #(
    parameter integer SCAN_TARGET_MAX=4, FLEXIBLE_SIZE=0,
    parameter [31:0] SCAN_START=0, SCAN_MAX=131071
)(
    input wire clk,rst,sd_init_done,
    output wire ready,
    output reg sd_sec_read, output reg [31:0] sd_sec_addr,
    input wire [7:0] sd_sec_data,
    input wire sd_sec_data_valid,sd_sec_end,sd_sec_busy,sd_sec_error,
    input wire [15:0] bmp_width,bmp_height,
    input wire scan_start,
    output reg scan_done,scan_found_valid,
    output reg [31:0] scan_found_sector,
    output reg [2:0] scan_found_total,
    input wire load_start,load_abort,
    input wire [31:0] load_sector,
    output reg write_req, input wire write_req_ack,
    output wire px_wr_en, output wire [23:0] px_data,
    input wire px_ready,
    output reg load_done,load_error,
    output wire progress,
    output reg [3:0] state_code,
    output wire [15:0] source_width,source_height,
    output wire source_top_down
);
    localparam IDLE=0,REQUEST=1,RECEIVE=2,HEADER=3,CHECK=4,
               WRITE_REQ=5,WRITE_RELEASE=6,PIXELS=7,DRAIN=8,PRECHECK=9,VALIDATE=10,ADDRESS=11,DIMENSIONS=12,SIZE=13;
    reg [3:0] state;
    reg scanning,header_sector;
    reg [7:0] sector_mem[0:511];
    reg [9:0] received;
    reg [8:0] pos;
    reg [5:0] header_pos;
    reg [31:0] base_sector,file_len,pixel_off,dib,width,height,compression;
    reg [15:0] signature,planes,bpp;
    reg [31:0] bytes_left;
    reg [1:0] phase;
    reg [7:0] blue,green;
    wire [7:0] byte_at_pos=sector_mem[pos];
    wire [7:0] header_byte=sector_mem[header_pos];
    reg [31:0] absolute_height,expected_bytes;
    reg [12:0] row_stride,row_payload,row_byte;
    wire padding=FLEXIBLE_SIZE && row_byte>=row_payload;
    assign source_width=width[15:0];
    assign source_height=absolute_height[15:0];
    assign source_top_down=height[31];
    reg header_fields_valid,header_valid;
    reg [31:0] payload_bytes;
    reg [32:0] rounded_len,scan_next,pixel_sector;
    assign ready=state==IDLE && sd_init_done && !sd_sec_busy;
    assign px_wr_en=state==PIXELS && phase==2 && !load_abort && !padding;
    assign px_data={byte_at_pos,green,blue};
    // Byte consumption is real forward progress too. Avoid routing the row
    // padding comparator through the player's inactivity watchdog.
    assign progress=sd_sec_data_valid ||
        (state==PIXELS && !load_abort && (phase!=2 || px_ready));
    always @(*) begin
        if(!sd_init_done) state_code=0;
        else if(load_error) state_code=4'he;
        else if(state==IDLE) state_code=1;
        else if(state==WRITE_REQ || state==WRITE_RELEASE) state_code=3;
        else if(state==PIXELS || (!scanning && !header_sector)) state_code=4;
        else state_code=2;
    end
    always @(posedge clk) if(state==RECEIVE && sd_sec_data_valid && received<512)
        sector_mem[received[8:0]]<=sd_sec_data;
    // Only HEADER consumes this index. Clear outside HEADER so receive/error
    // decoding is absent from the counter enable; entry still observes zero.
    always @(posedge clk or posedge rst) begin
        if(rst) header_pos<=0;
        else if(state!=HEADER) header_pos<=0;
        else if(!(load_abort && !scanning) && header_pos!=33) header_pos<=header_pos+1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            header_fields_valid<=0;header_valid<=0;payload_bytes<=0;rounded_len<=0;scan_next<=0;pixel_sector<=0;
            state<=IDLE;scanning<=0;header_sector<=1;received<=0;pos<=0;
            base_sector<=0;file_len<=0;pixel_off<=0;dib<=0;width<=0;height<=0;compression<=0;
            signature<=0;planes<=0;bpp<=0;bytes_left<=0;phase<=0;blue<=0;green<=0;row_byte<=0;
            absolute_height<=0;expected_bytes<=0;row_stride<=0;row_payload<=0;
            sd_sec_read<=0;sd_sec_addr<=0;scan_done<=0;scan_found_valid<=0;
            scan_found_sector<=0;scan_found_total<=0;write_req<=0;load_done<=0;load_error<=0;
        end else begin
            sd_sec_read<=0;scan_found_valid<=0;load_done<=0;
            if(load_abort && !scanning && state!=IDLE) begin
                state<=DRAIN;write_req<=0;load_error<=1;
            end else case(state)
                IDLE: if(ready) begin
                    if(scan_start) begin
                        scanning<=1;scan_done<=0;scan_found_total<=0;load_error<=0;
                        base_sector<=SCAN_START;sd_sec_addr<=SCAN_START;header_sector<=1;
                        state<=REQUEST;
                    end else if(load_start) begin
                        scanning<=0;load_error<=0;base_sector<=load_sector;
                        sd_sec_addr<=load_sector;header_sector<=1;state<=REQUEST;
                    end
                end
                REQUEST: if(!sd_sec_busy) begin
                    sd_sec_read<=1;received<=0;state<=RECEIVE;
                end
                RECEIVE: begin
                    if(sd_sec_data_valid && received<513) received<=received+1'b1;
                    if(sd_sec_end) begin
                        if(sd_sec_error || received!=512) begin
                            if(scanning) begin
                                if(base_sector>=SCAN_MAX) begin scan_done<=1;state<=IDLE;end
                                else begin base_sector<=base_sector+1;sd_sec_addr<=base_sector+1;state<=REQUEST;end
                            end else begin load_error<=1;load_done<=1;state<=IDLE;end
                        end else if(header_sector) begin
                            signature<=0;file_len<=0;pixel_off<=0;dib<=0;width<=0;height<=0;
                            planes<=0;bpp<=0;compression<=0;state<=HEADER;
                        end else state<=PIXELS;
                    end
                end
                HEADER: begin
                    case(header_pos)
                        0:signature[7:0]<=header_byte; 1:signature[15:8]<=header_byte;
                        2:file_len[7:0]<=header_byte;3:file_len[15:8]<=header_byte;
                        4:file_len[23:16]<=header_byte;5:file_len[31:24]<=header_byte;
                        10:pixel_off[7:0]<=header_byte;11:pixel_off[15:8]<=header_byte;
                        12:pixel_off[23:16]<=header_byte;13:pixel_off[31:24]<=header_byte;
                        14:dib[7:0]<=header_byte;15:dib[15:8]<=header_byte;
                        16:dib[23:16]<=header_byte;17:dib[31:24]<=header_byte;
                        18:width[7:0]<=header_byte;19:width[15:8]<=header_byte;
                        20:width[23:16]<=header_byte;21:width[31:24]<=header_byte;
                        22:height[7:0]<=header_byte;23:height[15:8]<=header_byte;
                        24:height[23:16]<=header_byte;25:height[31:24]<=header_byte;
                        26:planes[7:0]<=header_byte;27:planes[15:8]<=header_byte;
                        28:bpp[7:0]<=header_byte;29:bpp[15:8]<=header_byte;
                        30:compression[7:0]<=header_byte;31:compression[15:8]<=header_byte;
                        32:compression[23:16]<=header_byte;33:compression[31:24]<=header_byte;
                    endcase
                    if(header_pos==33) state<=DIMENSIONS;
                end
                DIMENSIONS: begin absolute_height<=height[31]?(~height+1'b1):height;state<=PRECHECK;end
                PRECHECK: begin
                    header_fields_valid<=signature==16'h4d42 && dib==40 &&
                        (FLEXIBLE_SIZE?(width>0 && width<=bmp_width && absolute_height>0 && absolute_height<=bmp_height):
                        (width=={16'd0,bmp_width} && height=={16'd0,bmp_height} &&
                        bmp_width!=0 && bmp_height!=0 && bmp_width[1:0]==0)) &&
                        planes==1 && bpp==24 && compression==0 && pixel_off>=54 && file_len>=pixel_off;
                    payload_bytes<=file_len-pixel_off;
                    rounded_len<={1'b0,file_len}+33'd511;
                    row_payload<=width[10:0]*13'd3;
                    row_stride<=(width[10:0]*13'd3+13'd3)&13'h1ffc;
                    state<=SIZE;
                end
                SIZE: begin
                    expected_bytes<=FLEXIBLE_SIZE?row_stride*absolute_height[9:0]:{16'd0,bmp_width}*{16'd0,bmp_height}*3;
                    state<=VALIDATE;
                end
                VALIDATE: begin
                    header_valid<=header_fields_valid && payload_bytes>=expected_bytes;
                    state<=ADDRESS;
                end
                ADDRESS: begin
                    scan_next<={1'b0,base_sector}+(header_valid?{9'd0,rounded_len[32:9]}:33'd1);
                    pixel_sector<={1'b0,base_sector}+{10'd0,pixel_off[31:9]};
                    state<=CHECK;
                end
                CHECK: if(scanning) begin
                    if(header_valid) begin
                        scan_found_valid<=1;scan_found_sector<=base_sector;
                        scan_found_total<=scan_found_total+1'b1;
                    end
                    if((header_valid && scan_found_total+1>=SCAN_TARGET_MAX) || scan_next>SCAN_MAX) begin
                        scan_done<=1;state<=IDLE;
                    end else begin base_sector<=scan_next[31:0];sd_sec_addr<=scan_next[31:0];state<=REQUEST;end
                end else if(!header_valid || pixel_sector[32]) begin
                    load_error<=1;load_done<=1;state<=IDLE;
                end else begin write_req<=1;state<=WRITE_REQ;end
                WRITE_REQ: if(write_req_ack) begin write_req<=0;state<=WRITE_RELEASE;end
                WRITE_RELEASE: if(!write_req_ack) begin
                    bytes_left<=expected_bytes;phase<=0;row_byte<=0;pos<=pixel_off[8:0];header_sector<=0;
                    sd_sec_addr<=pixel_sector[31:0];
                    state<=pixel_off<512?PIXELS:REQUEST;
                end
                PIXELS: if(padding || phase!=2 || px_ready) begin
                    if(!padding && phase==0) blue<=byte_at_pos;
                    if(!padding && phase==1) green<=byte_at_pos;
                    phase<=padding?0:phase==2?0:phase+1'b1;
                    row_byte<=row_byte==row_stride-1?0:row_byte+1'b1;
                    bytes_left<=bytes_left-1'b1;
                    pos<=pos+1'b1;
                    if(bytes_left==1) begin load_done<=1;state<=IDLE;end
                    else if(pos==511) begin
                        if(sd_sec_addr==32'hffffffff) begin load_error<=1;load_done<=1;state<=IDLE;end
                        else begin sd_sec_addr<=sd_sec_addr+1;state<=REQUEST;end
                    end
                end
                DRAIN: if(!sd_sec_busy) begin load_done<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
