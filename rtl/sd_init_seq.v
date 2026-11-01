`timescale 1ns/1ps
// SPI SD v1/v2 initialization. OCR.CCS selects block/byte addressing.
module sd_init_seq #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer POWER_WAIT=CLK_FREQ_HZ/1000,
    // Pause before each CMD55 of the ACMD41 loop; INIT_RETRIES bounds the loop.
    parameter integer RETRY_WAIT_CYCLES=POWER_WAIT,
    parameter integer INIT_RETRIES=1000,R1_BYTES=1024,
    // Host reset does not power-cycle the card. With init SCK <=400 kHz,
    // 8192 selected FF bytes cover 100 ms read latency + one 512-byte block,
    // token/R1/CRC and trailing clocks. This host issues CMD17 only, no writes.
    // Simulation may reduce the count together with its modeled read latency.
    // The drain runs only after a first attempt fails (a freshly powered card
    // answers CMD0 directly); the whole sequence is then repeated once.
    parameter integer RECOVERY_BYTES=8192
)(
    input wire clk,rst,
    output wire spi_start, output wire [7:0] spi_byte,
    input wire spi_busy,spi_done, input wire [7:0] rx_byte,
    output wire selected,
    output reg init_done,init_busy,block_addressing,
    output reg [3:0] err_code,
    output reg [11:0] command_diagnostic // phase 1..6 (CMD0/8/55/41/58/16), last R1
);
    localparam POWER=0,PRE_SEND=1,PRE_WAIT=2,CMD_START=3,CMD_WAIT=4,
               GAP_SEND=5,GAP_WAIT=6,RETRY_WAIT=7,COMPLETE=8,
               DRAIN_SEND=9,DRAIN_WAIT=10,DRAIN_GAP_SEND=11,DRAIN_GAP_WAIT=12;
    reg [3:0] state;
    reg [5:0] cmd;
    reg [31:0] arg;
    reg [7:0] crc;
    reg ext,v2,finish_pending,drained;
    reg [3:0] fault; // current attempt; err_code only reports the final outcome
    integer ticks,prebytes,attempts;
    wire cdone,ctimeout,cstart;
    wire [7:0] ctx,r1;
    wire [31:0] response;
    assign selected=state==CMD_START || state==CMD_WAIT || state==DRAIN_SEND || state==DRAIN_WAIT;
    assign spi_start=(state==PRE_SEND || state==GAP_SEND || state==DRAIN_SEND || state==DRAIN_GAP_SEND)?!spi_busy:cstart;
    assign spi_byte=(state==CMD_START || state==CMD_WAIT)?ctx:8'hff;
    sd_command #(.R1_BYTES(R1_BYTES)) command_engine(
        .clk(clk),.rst(rst),.start(state==CMD_START),.command(cmd),.argument(arg),.crc(crc),.extended(ext),
        .busy(),.done(cdone),.timeout(ctimeout),.r1(r1),.response(response),
        .spi_start(cstart),.spi_byte(ctx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx_byte));
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=POWER;ticks<=0;prebytes<=0;attempts<=0;
            init_done<=0;init_busy<=1;err_code<=0;fault<=0;block_addressing<=0;command_diagnostic<=0;
            cmd<=0;arg<=0;crc<=8'h95;ext<=0;v2<=0;finish_pending<=0;drained<=0;
        end else case(state)
            POWER: if(ticks>=POWER_WAIT-1) begin ticks<=0;state<=PRE_SEND;end else ticks<=ticks+1;
            PRE_SEND: if(!spi_busy) state<=PRE_WAIT;
            PRE_WAIT: if(spi_done) begin
                if(prebytes==9) begin prebytes<=0;state<=CMD_START;end
                else begin prebytes<=prebytes+1;state<=PRE_SEND;end
            end
            // Discard residual read bytes, including bit-7-clear payload that
            // would otherwise look like a CMD0 R1. Do not interpret it as status.
            DRAIN_SEND: if(!spi_busy) state<=DRAIN_WAIT;
            DRAIN_WAIT: if(spi_done) begin
                if(prebytes>=RECOVERY_BYTES-1) state<=DRAIN_GAP_SEND;
                else begin prebytes<=prebytes+1;state<=DRAIN_SEND;end
            end
            DRAIN_GAP_SEND: if(!spi_busy) state<=DRAIN_GAP_WAIT;
            DRAIN_GAP_WAIT: if(spi_done) state<=CMD_START;
            CMD_START: state<=CMD_WAIT;
            CMD_WAIT: if(cdone) begin
                case(cmd)
                    0:command_diagnostic<={4'd1,r1};
                    8:command_diagnostic<={4'd2,r1};
                    55:command_diagnostic<={4'd3,r1};
                    41:command_diagnostic<={4'd4,r1};
                    58:command_diagnostic<={4'd5,r1};
                    16:command_diagnostic<={4'd6,r1};
                    default:command_diagnostic<={4'd0,r1};
                endcase
                state<=GAP_SEND;crc<=8'hff;ext<=0;
                if(ctimeout) begin fault<=1;finish_pending<=1;end
                else case(cmd)
                    0: if(r1==1) begin cmd<=8;arg<=32'h1aa;crc<=8'h87;ext<=1;end
                       else begin fault<=2;finish_pending<=1;end
                    8: if(r1==1 && response[11:0]==12'h1aa) begin v2<=1;cmd<=55;arg<=0;end
                       else if(r1==5) begin v2<=0;cmd<=55;arg<=0;end
                       else begin fault<=3;finish_pending<=1;end
                    55: if(r1==1 || r1==0) begin cmd<=41;arg<=v2?32'h40000000:0;end
                        else begin fault<=2;finish_pending<=1;end
                    41: if(r1==0) begin cmd<=58;arg<=0;ext<=1;end
                        else if(r1==1 && attempts<INIT_RETRIES-1) begin
                            attempts<=attempts+1;cmd<=55;arg<=0;
                        end else begin fault<=4;finish_pending<=1;end
                    58: if(r1==0 && response[31] && |response[23:15]) begin
                            block_addressing<=v2 && response[30];
                            if(v2 && response[30]) finish_pending<=1;
                            else begin cmd<=16;arg<=512;end
                        end else begin fault<=3;finish_pending<=1;end
                    16: begin finish_pending<=1;if(r1!=0) fault<=2;end
                    default: begin fault<=2;finish_pending<=1;end
                endcase
            end
            GAP_SEND: if(!spi_busy) state<=GAP_WAIT;
            GAP_WAIT: if(spi_done) begin
                ticks<=0;
                if(finish_pending && fault!=0 && !drained) begin
                    // A host-only reset may have left the card inside a read: drain
                    // its residual bytes, then restart the whole sequence once.
                    drained<=1;fault<=0;finish_pending<=0;prebytes<=0;attempts<=0;
                    cmd<=0;arg<=0;crc<=8'h95;ext<=0;v2<=0;state<=DRAIN_SEND;
                end else if(finish_pending) begin init_done<=fault==0;err_code<=fault;state<=COMPLETE;end
                else state<=cmd==55?RETRY_WAIT:CMD_START;
            end
            RETRY_WAIT: if(ticks>=RETRY_WAIT_CYCLES-1) state<=CMD_START;else ticks<=ticks+1;
            COMPLETE: init_busy<=0;
            default: state<=POWER;
        endcase
    end
endmodule
