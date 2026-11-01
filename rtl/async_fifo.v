`timescale 1ns/1ps
// Anlogic Soft_FIFO 3.0, async ERAM, show-ahead head normalized to one read register.
// Full 10-bit watermarks include 512. Reset completion gates both external ports.
module async_fifo #(parameter W=32,DEPTH=512,LW=9)(
    input wire wr_clk,rd_clk,rst,wr_en,
    input wire [W-1:0] wr_data,
    output reg [W-1:0] rd_data,
    input wire rd_en,
    output wire empty,full,
    output wire [LW:0] rd_used,wr_used,
    output reg rd_valid,
    output wire wr_ready,rd_ready
);
    wire [W-1:0] head;
    wire ip_empty,ip_full;
    wire wr_done,rd_done;
    wire wr_rst,rd_rst;
    reset_sync wreset(.clk(wr_clk),.arst(rst),.rst(wr_rst));
    reset_sync rreset(.clk(rd_clk),.arst(rst),.rst(rd_rst));
    // Show-ahead IP watermarks include reserved prefetch slots. Track accepted
    // external words separately; cap the public capacity at exactly DEPTH.
    reg [LW:0] wr_count,rd_count,wr_gray,rd_gray;
    (* async_reg="true" *) reg [LW:0] rd_sync1,rd_sync2,wr_sync1,wr_sync2;
    wire put=wr_en && !full;
    wire get=rd_en && !empty;
    wire [LW:0] wr_next=wr_count+put;
    wire [LW:0] rd_next=rd_count+get;
    function [LW:0] binary(input [LW:0] gray);
        integer bitnum;
        begin
            binary[LW]=gray[LW];
            for(bitnum=LW-1;bitnum>=0;bitnum=bitnum-1)
                binary[bitnum]=binary[bitnum+1]^gray[bitnum];
        end
    endfunction
    assign wr_used=wr_count-binary(rd_sync2);
    assign rd_used=binary(wr_sync2)-rd_count;
    always @(posedge wr_clk or posedge wr_rst) begin
        if(wr_rst) begin wr_count<=0;wr_gray<=0;rd_sync1<=0;rd_sync2<=0;end
        else begin
            wr_count<=wr_next;wr_gray<=(wr_next>>1)^wr_next;
            rd_sync1<=rd_gray;rd_sync2<=rd_sync1;
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if(rd_rst) begin rd_count<=0;rd_gray<=0;wr_sync1<=0;wr_sync2<=0;end
        else begin
            rd_count<=rd_next;rd_gray<=(rd_next>>1)^rd_next;
            wr_sync1<=wr_gray;wr_sync2<=wr_sync1;
        end
    end
    assign wr_ready=wr_done && !wr_rst;
    assign rd_ready=rd_done && !rd_rst;
    assign full=!wr_ready || ip_full || wr_used>=DEPTH;
    assign empty=!rd_ready || ip_empty || rd_used==0;
    soft_fifo #(
        .COMMON_CLK_EN(0),.MEMORY_TYPE(2),.RST_TYPE(1),
        .DATA_WIDTH_W(W),.DATA_WIDTH_R(W),.ADDR_WIDTH_W(LW),.ADDR_WIDTH_R(LW),
        .DOUT_INITVAL(0),.OUTREG_EN("NOREG"),.SHOW_AHEAD_EN(1),
        .AL_FULL_NUM(DEPTH-4),.AL_EMPTY_NUM(2),
        .WRUSEDW_WIDTH(LW+1),.RDUSEDW_WIDTH(LW+1),
        .ASYNC_RST_SYNC_RELS(1),.SYNC_STAGE(3)
    ) fifo_ip(
        .rst(rst),.srst(1'b0),.wrst(1'b0),.rrst(1'b0),.clk(1'b0),
        .clkw(wr_clk),.clkr(rd_clk),.we(wr_en && !full),.re(rd_en && !empty),
        .di(wr_data),.dout(head),.valid(),.wr_success(),.overflow(),.underflow(),
        .empty_flag(ip_empty),.full_flag(ip_full),.aempty(),.afull(),
        .rdusedw(),.wrusedw(),.wr_rst_done(wr_done),.rd_rst_done(rd_done));
    always @(posedge rd_clk or posedge rd_rst) begin
        if(rd_rst) begin rd_data<=0;rd_valid<=0;end
        else begin
            rd_valid<=rd_en && !empty;
            if(rd_en && !empty) rd_data<=head;
        end
    end
endmodule
