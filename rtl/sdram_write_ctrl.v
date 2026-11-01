`timescale 1ns/1ps
// Four-phase frame request/abort; 256-word reservations, registered FIFO reads.
module sdram_write_ctrl #(
    parameter MEM_DATA_BITS=32,ADDR_BITS=21,BURST_SIZE=256,
    parameter FRAME_WIDTH=640,FRAME_HEIGHT=480,WRITE_V_FLIP=1,DYNAMIC_ORIENTATION=0
)(
    input wire clk_sd,mem_clk,rst,
    input wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,rd_busy,
    output wire wr_busy,
    input wire write_req,output wire write_req_ack,
    input wire write_abort,output wire write_abort_ack,
    input wire [ADDR_BITS-1:0] write_addr0,write_addr1,write_addr2,write_addr3,write_len,
    input wire [1:0] write_addr_idx,
    input wire write_en,input wire [MEM_DATA_BITS-1:0] write_data,
    output wire write_ready,output reg write_finish,
    output wire [3:0] App_wr_dm,
    output wire App_wr_en,
    output reg [ADDR_BITS-1:0] App_wr_addr,
    output wire [MEM_DATA_BITS-1:0] App_wr_din,
    input wire source_top_down
);
    wire mem_rst,other_rst;
    reset_sync mr(.clk(mem_clk),.arst(rst),.rst(mem_rst));
    reset_sync sr(.clk(clk_sd),.arst(rst),.rst(other_rst));
    localparam IDLE=0,CLEAR=1,RELEASE=2,ACK=3,WAIT_DATA=4,BURST=5,DRAIN=6,ABORT=7;
    reg [3:0] state;
    (* async_reg="true" *) reg [2:0] req_sync,abort_sync;
    (* async_reg="true" *) reg [1:0] ack_sync,abort_ack_sync,wr_ready_sync,active_sync;
    reg ack_mem,abort_ack_mem,fifo_reset,active;
    reg [4:0] reset_count;
    reg [ADDR_BITS-1:0] remaining;
    reg [8:0] issued,burst_words;
    reg [15:0] x;
    reg flip;
    wire requested_flip=WRITE_V_FLIP && (!DYNAMIC_ORIENTATION || !source_top_down);
    wire [9:0] used;
    wire empty,full,valid,wr_ready_ip,rd_ready_ip;
    wire pop=state==BURST && issued<burst_words && !empty && !abort_sync[2];
    wire [ADDR_BITS-1:0] next_words=remaining<BURST_SIZE?remaining:BURST_SIZE;
    assign wr_busy=state==BURST || state==DRAIN ||
        (state==WAIT_DATA && used>=next_words && !rd_busy && Sdr_init_done && !Sdr_busy && !Sdr_init_ref_vld);
    assign write_req_ack=ack_sync[1];
    assign write_abort_ack=abort_ack_sync[1];
    assign write_ready=active_sync[1] && !full;
    assign App_wr_dm=0;
    assign App_wr_en=valid && (state==BURST || state==DRAIN) && !abort_sync[2];
    async_fifo #(.W(MEM_DATA_BITS)) wfifo(
        .wr_clk(clk_sd),.rd_clk(mem_clk),.rst(rst || fifo_reset),
        .wr_en(write_en && write_ready),.wr_data(write_data),.rd_en(pop),.rd_data(App_wr_din),
        .empty(empty),.full(full),.rd_used(used),.wr_used(),.rd_valid(valid),
        .wr_ready(wr_ready_ip),.rd_ready(rd_ready_ip));
    always @(posedge clk_sd or posedge other_rst) begin
        if(other_rst) begin ack_sync<=0;abort_ack_sync<=0;active_sync<=0;end
        else begin
            ack_sync<={ack_sync[0],ack_mem};
            abort_ack_sync<={abort_ack_sync[0],abort_ack_mem};
            active_sync<={active_sync[0],active};
        end
    end
    always @(posedge mem_clk or posedge mem_rst) begin
        if(mem_rst) begin req_sync<=0;abort_sync<=0;wr_ready_sync<=0;end
        else begin
            req_sync<={req_sync[1:0],write_req};
            abort_sync<={abort_sync[1:0],write_abort};
            wr_ready_sync<={wr_ready_sync[0],wr_ready_ip};
        end
    end
    always @(posedge mem_clk or posedge mem_rst) begin
        if(mem_rst) begin
            state<=IDLE;ack_mem<=0;abort_ack_mem<=0;fifo_reset<=1;active<=0;
            reset_count<=0;remaining<=0;issued<=0;burst_words<=0;x<=0;flip<=WRITE_V_FLIP;
            App_wr_addr<=0;write_finish<=0;
        end else begin
            write_finish<=0;
            if(abort_sync[2]) begin
                state<=ABORT;abort_ack_mem<=1;ack_mem<=0;fifo_reset<=1;active<=0;
            end else begin
                case(state)
                    IDLE: if(req_sync[2] && Sdr_init_done) begin
                        fifo_reset<=1;reset_count<=0;remaining<=write_len;x<=0;flip<=requested_flip;
                        case(write_addr_idx)
                            0:App_wr_addr<=write_addr0+(requested_flip?(FRAME_HEIGHT-1)*FRAME_WIDTH:0);
                            1:App_wr_addr<=write_addr1+(requested_flip?(FRAME_HEIGHT-1)*FRAME_WIDTH:0);
                            2:App_wr_addr<=write_addr2+(requested_flip?(FRAME_HEIGHT-1)*FRAME_WIDTH:0);
                            3:App_wr_addr<=write_addr3+(requested_flip?(FRAME_HEIGHT-1)*FRAME_WIDTH:0);
                        endcase
                        state<=CLEAR;
                    end
                    CLEAR: if(reset_count==7) begin fifo_reset<=0;state<=RELEASE;end
                           else reset_count<=reset_count+1'b1;
                    RELEASE: if(wr_ready_sync[1] && rd_ready_ip) begin active<=1;ack_mem<=1;state<=ACK;end
                    ACK: if(!req_sync[2]) begin ack_mem<=0;state<=WAIT_DATA;end
                    WAIT_DATA: if(remaining==0) begin
                            write_finish<=1;active<=0;state<=IDLE;fifo_reset<=1;
                        end else if(used>=next_words && !rd_busy && Sdr_init_done && !Sdr_busy && !Sdr_init_ref_vld) begin
                            burst_words<=next_words[8:0];issued<=0;state<=BURST;
                        end
                    BURST: if(pop) begin
                        issued<=issued+1'b1;
                        if(issued+1==burst_words) state<=DRAIN;
                    end
                    DRAIN: if(!valid) state<=WAIT_DATA;
                    ABORT: begin abort_ack_mem<=0;state<=IDLE;end
                    default: state<=IDLE;
                endcase
                if(App_wr_en) begin
                    remaining<=remaining-1'b1;
                    if(flip && x==FRAME_WIDTH-1) begin x<=0;App_wr_addr<=App_wr_addr-(2*FRAME_WIDTH-1);end
                    else begin x<=x+1'b1;App_wr_addr<=App_wr_addr+1'b1;end
                end
            end
        end
    end
endmodule
