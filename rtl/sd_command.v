`timescale 1ns/1ps
// One 0xFF Ncs byte, six command bytes, bounded R1 polling, optional four-byte R3/R7.
module sd_command #(parameter integer R1_BYTES=1024)(
    input wire clk,rst,start,
    input wire [5:0] command, input wire [31:0] argument,
    input wire [7:0] crc, input wire extended,
    output wire busy, output reg done,timeout,
    output reg [7:0] r1, output reg [31:0] response,
    output wire spi_start, output wire [7:0] spi_byte,
    input wire spi_busy,spi_done, input wire [7:0] rx_byte
);
    localparam IDLE=0,PRE=1,SEND=2,WAIT_BYTE=3;
    reg [1:0] state;
    reg [3:0] index;
    reg [47:0] packet;
    reg want_extended;
    integer polls;
    assign busy=state!=IDLE;
    assign spi_start=(state==PRE || state==SEND) && !spi_busy;
    assign spi_byte=(state==SEND && index<6)?packet[47:40]:8'hff;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;index<=0;packet<=0;want_extended<=0;
            done<=0;timeout<=0;r1<=8'hff;response<=0;polls<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    packet<={2'b01,command,argument,crc};index<=0;
                    want_extended<=extended;response<=0;r1<=8'hff;
                    timeout<=0;polls<=0;state<=PRE;
                end
                PRE: if(!spi_busy) state<=SEND;
                SEND: if(!spi_busy) state<=WAIT_BYTE;
                WAIT_BYTE: if(spi_done) begin
                    state<=SEND;
                    if(index<6) begin packet<={packet[39:0],8'hff};index<=index+1'b1;end
                    else if(index==6) begin
                        if(!rx_byte[7]) begin
                            r1<=rx_byte;
                            if(want_extended && (rx_byte==0 || rx_byte==1)) index<=7;
                            else begin done<=1;state<=IDLE;end
                        end else if(polls==R1_BYTES-1) begin
                            timeout<=1;done<=1;state<=IDLE;
                        end else polls<=polls+1;
                    end else begin
                        response<={response[23:0],rx_byte};
                        if(index==10) begin done<=1;state<=IDLE;end
                        else index<=index+1'b1;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
