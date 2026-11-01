`timescale 1ns/1ps
// sec_read is a one-cycle request accepted while !busy. Errors finish explicitly.
module sd_rw_sector #(
    // At DIV=3, each polled byte takes at least 480 ns: allow >100 ms.
    parameter integer RETRY_MAX=16,TOKEN_TIMEOUT=262144,R1_BYTES=1024
)(
    input wire clk,rst,sec_read,
    input wire [31:0] sec_addr, input wire block_addressing,
    output reg [7:0] sec_data,
    output reg sec_data_valid,sec_end,sec_error,
    output reg [11:0] read_diagnostic,
    output wire busy,selected,spi_start, output wire [7:0] spi_byte,
    input wire spi_busy,spi_done, input wire [7:0] rx_byte
);
    localparam IDLE=0,CSTART=1,CWAIT=2,TOKEN_SEND=3,TOKEN_WAIT=4,
               DATA_SEND=5,DATA_WAIT=6,GAP_SEND=7,GAP_WAIT=8,END=9;
    reg [3:0] state;
    reg [31:0] argument;
    reg retry_pending;
    reg [15:0] data_crc;
    reg [7:0] received_crc_hi;
    function [15:0] crc16_byte(input [15:0] previous,input [7:0] value);
        reg [15:0] c;
        integer bit_number;
        begin
            c=previous;
            for(bit_number=7;bit_number>=0;bit_number=bit_number-1)
                c={c[14:0],1'b0} ^ ((c[15]^value[bit_number])?16'h1021:16'h0000);
            crc16_byte=c;
        end
    endfunction
    integer attempts,token_count,data_count;
    wire cdone,ctimeout,cstart;
    wire [7:0] ctx,r1;
    assign busy=state!=IDLE;
    assign selected=state>=CSTART && state<=DATA_WAIT;
    assign spi_start=(state==TOKEN_SEND || state==DATA_SEND || state==GAP_SEND)?!spi_busy:cstart;
    assign spi_byte=(state==CSTART || state==CWAIT)?ctx:8'hff;
    sd_command #(.R1_BYTES(R1_BYTES)) command_engine(
        .clk(clk),.rst(rst),.start(state==CSTART),.command(6'd17),.argument(argument),.crc(8'hff),.extended(1'b0),
        .busy(),.done(cdone),.timeout(ctimeout),.r1(r1),.response(),
        .spi_start(cstart),.spi_byte(ctx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx_byte));
    // Sticky error has independent set conditions; avoid a priority mux
    // through unrelated command/token/data state updates on its enable.
    wire command_failed=state==CWAIT && cdone && (ctimeout || r1!=0) && attempts>=RETRY_MAX-1;
    wire token_failed=state==TOKEN_WAIT && spi_done && rx_byte!=8'hfe &&
        (token_count>=TOKEN_TIMEOUT-1 || rx_byte!=8'hff);
    wire crc_failed=state==DATA_WAIT && spi_done && data_count==513 && {received_crc_hi,rx_byte}!=data_crc;
    always @(posedge clk or posedge rst) begin
        if(rst) sec_error<=0;
        else if(state==IDLE && sec_read) sec_error<=!block_addressing && |sec_addr[31:23];
        else if(command_failed || token_failed || crc_failed) sec_error<=1;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;argument<=0;attempts<=0;token_count<=0;data_count<=0;
            sec_data<=0;sec_data_valid<=0;sec_end<=0;retry_pending<=0;
            read_diagnostic<=0;data_crc<=0;received_crc_hi<=0;
        end else begin
            sec_data_valid<=0;sec_end<=0;
            case(state)
                IDLE: if(sec_read) begin
                    argument<=block_addressing?sec_addr:(sec_addr<<9);
                    attempts<=0;retry_pending<=0;read_diagnostic<=0;state<=CSTART;
                    if(!block_addressing && |sec_addr[31:23]) begin read_diagnostic<=12'h500;state<=END;end
                end
                CSTART: state<=CWAIT;
                CWAIT: if(cdone) begin
                    if(!ctimeout && r1==0) begin token_count<=0;state<=TOKEN_SEND;end
                    else begin
                        retry_pending<=attempts<RETRY_MAX-1;
                        if(attempts>=RETRY_MAX-1) begin
                            read_diagnostic<={(ctimeout ? 4'd1 : 4'd2),r1};
                        end
                        attempts<=attempts+1;state<=GAP_SEND;
                    end
                end
                TOKEN_SEND: if(!spi_busy) state<=TOKEN_WAIT;
                TOKEN_WAIT: if(spi_done) begin
                    if(rx_byte==8'hfe) begin data_count<=0;data_crc<=0;state<=DATA_SEND;end
                    else if(token_count>=TOKEN_TIMEOUT-1 || rx_byte!=8'hff) begin
                        retry_pending<=0;state<=GAP_SEND;
                        read_diagnostic<={(rx_byte==8'hff ? 4'd3 : 4'd4),rx_byte};
                    end else begin token_count<=token_count+1;state<=TOKEN_SEND;end
                end
                DATA_SEND: if(!spi_busy) state<=DATA_WAIT;
                DATA_WAIT: if(spi_done) begin
                    if(data_count<512) begin
                        sec_data<=rx_byte;sec_data_valid<=1;data_crc<=crc16_byte(data_crc,rx_byte);
                    end else if(data_count==512) received_crc_hi<=rx_byte;
                    if(data_count==513) begin
                        retry_pending<=0;state<=GAP_SEND;
                        if({received_crc_hi,rx_byte}!=data_crc) begin
                            read_diagnostic<=12'h600;
                        end
                    end
                    else begin data_count<=data_count+1;state<=DATA_SEND;end
                end
                GAP_SEND: if(!spi_busy) state<=GAP_WAIT;
                GAP_WAIT: if(spi_done) state<=retry_pending?CSTART:END;
                END: begin sec_end<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
