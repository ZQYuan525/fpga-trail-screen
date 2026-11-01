`timescale 1ns/1ps
// SD SPI mode 3 (idle-high SCK). Chip selection belongs to a transaction, not a byte.
module sd_spi #(parameter integer DIV=3, LOW_DIV=250)(
    input wire clk,rst,selected,low_speed,spi_start,
    input wire [7:0] spi_byte,
    output reg spi_busy,spi_done,
    output reg [7:0] rx_byte,
    output reg sck,mosi, output wire cs, input wire miso
);
    localparam integer HALF_W=$clog2((DIV>LOW_DIV?DIV:LOW_DIV)+1);
    reg [HALF_W-1:0] count,half_period;
    reg [2:0] bit_index;
    reg [7:0] tx,rx;
    reg first_edge,finish;
    assign cs=~selected;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            spi_busy<=0;spi_done<=0;rx_byte<=0;sck<=1;mosi<=1;
            count<=0;bit_index<=7;tx<=0;rx<=0;half_period<=LOW_DIV;first_edge<=1;finish<=0;
        end else begin
            spi_done<=0;
            if(!spi_busy) begin
                sck<=1;
                if(spi_start) begin
                    tx<=spi_byte;mosi<=spi_byte[7];rx<=0;
                    half_period<=low_speed?LOW_DIV:DIV;
                    bit_index<=7;count<=0;first_edge<=1;finish<=0;spi_busy<=1;
                end else mosi<=1;
            end else if(finish) begin
                // rx alone samples the pad: a second MISO register would be
                // packed into the input IOB and fail the MCP hold check.
                rx_byte<=rx;spi_done<=1;spi_busy<=0;finish<=0;
            end else if(count==half_period-1) begin
                count<=0;sck<=~sck;
                if(!sck) begin
                    // Rising edge: sample MISO; the card samples MOSI at this
                    // edge, so MOSI must not change here. The 8th sample ends
                    // the byte on the next cycle.
                    rx<={rx[6:0],miso};
                    if(bit_index==0) finish<=1;
                end else if(first_edge) begin
                    // Byte-leading falling edge: the card launches its first
                    // MISO bit; MOSI still holds bit 7.
                    first_edge<=0;
                end else begin
                    bit_index<=bit_index-1'b1;
                    tx<={tx[6:0],1'b1};mosi<=tx[6];
                end
            end else count<=count+1'b1;
        end
    end
endmodule
