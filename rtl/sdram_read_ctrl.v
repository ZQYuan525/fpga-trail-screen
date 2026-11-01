`timescale 1ns/1ps
// Frame-boundary adoption owns buffer release. No old memory reads remain when
// publish_ack rises. Display consumes the FIFO only on its explicit pixel request.
module sdram_read_ctrl #(
    parameter MEM_DATA_BITS=32,ADDR_BITS=21,BURST_SIZE=256,
    parameter integer RETURN_TIMEOUT=4096,
    parameter integer WIPE_FRAMES=0,MANUAL_FADE=0,ENHANCED_WIPE=0
)(
    input wire mem_clk,clk_video,rst,
    input wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,wr_busy,
    output wire rd_busy,
    input wire read_req,output wire read_req_ack,
    output reg read_finish,
    input wire publish_req,input wire [1:0] publish_buf,
    input wire publish_fade,
    input wire [1:0] wipe_kind,
    input wire [1:0] publish_image,output reg [1:0] display_image,
    output reg publish_ack,output reg display_valid,
    input wire [ADDR_BITS-1:0] read_addr0,read_addr1,read_addr2,read_addr3,read_len,
    input wire Sdr_rd_en,input wire [MEM_DATA_BITS-1:0] Sdr_rd_dout,
    output wire App_rd_en,output reg [ADDR_BITS-1:0] App_rd_addr,
    input wire read_en,
    output wire [MEM_DATA_BITS-1:0] read_data,
    output wire read_valid,
    output reg memory_error,output reg underflow
);
    wire mem_rst,other_rst;
    reset_sync mr(.clk(mem_clk),.arst(rst),.rst(mem_rst));
    reset_sync sr(.clk(clk_video),.arst(rst),.rst(other_rst));
    localparam IDLE=0,CLEAR=1,RELEASE=2,ACK=3,WAIT_SPACE=4,ISSUE=5,DRAIN=6,FAULT=7;
    reg [3:0] state;
    (* async_reg="true" *) reg [2:0] req_sync,publish_sync;
    (* async_reg="true" *) reg [1:0] ack_sync,rd_ready_sync;
    reg ack_mem,fifo_reset;
    reg [1:0] active_buf;
    reg wiping;
    reg [1:0] kind_q;
    reg [ADDR_BITS-1:0] new_base;
    reg [ADDR_BITS-1:0] wipe_words,offset,old_base;
    wire [ADDR_BITS-1:0] wipe_step=WIPE_FRAMES>0?read_len/WIPE_FRAMES:read_len;
    wire [ADDR_BITS-1:0] wipe_begin=!ENHANCED_WIPE || kind_q==0?0:
        kind_q==1?read_len-wipe_words:(read_len>>1)-(wipe_words>>1);
    wire [ADDR_BITS-1:0] wipe_end=!ENHANCED_WIPE || kind_q==0?wipe_words:
        kind_q==1?read_len:((read_len>>1)-(wipe_words>>1))+wipe_words;
    function [ADDR_BITS-1:0] base;
        input [1:0] index;
        begin case(index)
            0:base=read_addr0;1:base=read_addr1;2:base=read_addr2;3:base=read_addr3;
        endcase end
    endfunction
    reg [4:0] reset_count,guard;
    reg [ADDR_BITS-1:0] remaining;
    reg [8:0] issued,returned,burst_words;
    integer watchdog;
    wire [9:0] used;
    wire empty,full,wr_ready_ip,rd_ready_ip;
    wire [ADDR_BITS-1:0] next_words=remaining<BURST_SIZE?remaining:BURST_SIZE;
    wire returning=Sdr_rd_en && (state==ISSUE || state==DRAIN);
    assign rd_busy=state==ISSUE || state==DRAIN;
    assign App_rd_en=state==ISSUE && issued<burst_words;
    assign read_req_ack=ack_sync[1];
    async_fifo #(.W(MEM_DATA_BITS)) rfifo(
        .wr_clk(mem_clk),.rd_clk(clk_video),.rst(rst || fifo_reset),
        .wr_en(returning),.wr_data(Sdr_rd_dout),
        .rd_en(read_en),.rd_data(read_data),.empty(empty),.full(full),
        .rd_used(),.wr_used(used),.rd_valid(read_valid),.wr_ready(wr_ready_ip),.rd_ready(rd_ready_ip));
    always @(posedge clk_video or posedge other_rst) begin
        if(other_rst) begin ack_sync<=0;underflow<=0;end
        else begin
            ack_sync<={ack_sync[0],ack_mem};
            if(read_en && empty) underflow<=1;
        end
    end
    always @(posedge mem_clk or posedge mem_rst) begin
        if(mem_rst) begin req_sync<=0;publish_sync<=0;rd_ready_sync<=0;end
        else begin
            req_sync<={req_sync[1:0],read_req};
            publish_sync<={publish_sync[1:0],publish_req};
            rd_ready_sync<={rd_ready_sync[0],rd_ready_ip};
        end
    end
    always @(posedge mem_clk or posedge mem_rst) begin
        if(mem_rst) begin
            state<=IDLE;ack_mem<=0;fifo_reset<=1;active_buf<=0;wiping<=0;wipe_words<=0;offset<=0;old_base<=0;
            reset_count<=0;guard<=0;remaining<=0;issued<=0;returned<=0;burst_words<=0;watchdog<=0;
            kind_q<=0;new_base<=0;read_finish<=0;App_rd_addr<=0;publish_ack<=0;display_valid<=0;memory_error<=0;display_image<=0;
        end else begin
            read_finish<=0;
            if(!publish_sync[2]) publish_ack<=0;
            case(state)
                IDLE: if(req_sync[2] && Sdr_init_done) begin
                    // Metadata has been stable for the request synchronizer latency.
                    if(publish_sync[2] && !publish_ack) begin
                        if((MANUAL_FADE && publish_fade) || WIPE_FRAMES<2 || !display_valid || wipe_step==0 ||
                           (wiping && wipe_words+wipe_step>=read_len)) begin
                            active_buf<=publish_buf;publish_ack<=1;display_valid<=1;wiping<=0;
                            display_image<=publish_image;
                        end else begin
                            wiping<=1;wipe_words<=wiping?wipe_words+wipe_step:wipe_step;
                            if(!wiping) kind_q<=ENHANCED_WIPE?wipe_kind:0;
                        end
                    end
                    fifo_reset<=1;reset_count<=0;state<=CLEAR;
                end
                CLEAR: if(reset_count==7) begin fifo_reset<=0;state<=RELEASE;end
                       else reset_count<=reset_count+1'b1;
                RELEASE: if(wr_ready_ip && rd_ready_sync[1]) begin
                    App_rd_addr<=base(wiping && wipe_begin==0?publish_buf:active_buf);
                    new_base<=base(publish_buf);
                    old_base<=base(active_buf);offset<=0;
                    remaining<=read_len;ack_mem<=1;state<=ACK;
                end
                ACK: if(!req_sync[2]) begin ack_mem<=0;state<=display_valid?WAIT_SPACE:IDLE;end
                WAIT_SPACE: if(remaining==0) begin read_finish<=1;state<=IDLE;end
                    else if(used+next_words<=512 && !wr_busy && Sdr_init_done && !Sdr_busy && !Sdr_init_ref_vld) begin
                        burst_words<=next_words[8:0];issued<=0;returned<=0;guard<=0;watchdog<=0;state<=ISSUE;
                    end
                ISSUE: begin
                    issued<=issued+1'b1;offset<=offset+1'b1;guard<=0;
                    if(wiping && offset+1'b1==wipe_begin) App_rd_addr<=new_base+offset+1'b1;
                    else if(wiping && offset+1'b1==wipe_end) App_rd_addr<=old_base+offset+1'b1;
                    else App_rd_addr<=App_rd_addr+1'b1;
                    if(issued+1==burst_words) state<=DRAIN;
                end
                DRAIN: begin
                    if(guard<10) guard<=guard+1'b1;
                    if(returned==burst_words && guard==10) begin remaining<=remaining-burst_words;state<=WAIT_SPACE;end
                    else if(watchdog>=RETURN_TIMEOUT-1) begin
                        memory_error<=1;display_valid<=0;fifo_reset<=1;state<=FAULT;
                    end
                end
                // Late responses after a failed transaction cannot seed another frame.
                // Memory protocol faults require the common board reset.
                FAULT: begin ack_mem<=0;display_valid<=0;fifo_reset<=1;end
                default: state<=IDLE;
            endcase
            if(state==ISSUE || state==DRAIN) watchdog<=watchdog+1;
            if(returning) begin
                returned<=returned+1'b1;watchdog<=0;
                if(full || returned>=burst_words) begin
                    memory_error<=1;display_valid<=0;fifo_reset<=1;state<=FAULT;
                end
            end
        end
    end
endmodule
