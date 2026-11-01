`timescale 1ns/1ps
// Independent SD SPI card model: samples MOSI on SCK rising, drives MISO on SCK
// falling, so the same behavior serves mode-0 and mode-3 hosts. Checks complete
// commands, CS, CRC and APP_CMD.
module sd_card_model #(parameter BMP_HEADERS=0, KEEP_READ_ON_DESELECT=0)(
    input wire rst,cs,sck,mosi,output reg miso,
    input wire [1:0] card_type,input wire [3:0] fault,
    output integer command17_count,output integer preclocks
);
    reg [7:0] rxshift,txshift;
    reg [7:0] packet[0:5],response[0:8191];
    integer bitpos,cmdpos,wr,rd,attempts,i;
    reg app_cmd,card_ready,read_pending;
    reg [31:0] arg,sector;
    reg [7:0] received;
    reg [15:0] crc;
    reg [7:0] payload;
    integer crc_bit;
    function [7:0] bmp_byte(input integer lba,offset);
        begin
            bmp_byte=0;
            if(lba==0 || lba==1801 || lba==3602 || lba==5403) case(offset)
                0:bmp_byte=8'h42;1:bmp_byte=8'h4d;
                2:bmp_byte=8'h36;3:bmp_byte=8'h10;4:bmp_byte=8'h0e;
                10:bmp_byte=54;14:bmp_byte=40;
                18:bmp_byte=8'h80;19:bmp_byte=2;
                22:bmp_byte=8'he0;23:bmp_byte=1;
                26:bmp_byte=1;28:bmp_byte=24;
            endcase
        end
    endfunction
    task enqueue(input [7:0] value);
        begin response[wr]=value;wr=wr+1;end
    endtask
    always @(posedge rst) begin
        miso=1;rxshift=0;txshift=8'hff;bitpos=0;cmdpos=0;wr=0;rd=0;
        attempts=0;app_cmd=0;card_ready=0;read_pending=0;command17_count=0;preclocks=0;
    end
    always @(negedge cs) if(!rst) begin
        rxshift=0;txshift=8'hff;miso=1;bitpos=0;cmdpos=0;
        // A powered card may still owe a read response/data block after host reset.
        // CS starts byte framing; it is not a card power reset in this variant.
        // An emptied queue owes nothing even if no low-CS SCK falling edge has
        // dequeued past it yet (mode 3 has no trailing falling edge per byte).
        if(!KEEP_READ_ON_DESELECT || !read_pending || rd>=wr) begin wr=0;rd=0;read_pending=0;end
    end
    always @(posedge cs) if(!rst) begin
        if(cmdpos!=0 && !KEEP_READ_ON_DESELECT) $fatal(1,"SD CS released before all six command bytes");
        miso=1;
    end
    always @(posedge sck) if(!rst) begin
        if(cs) begin
            if(!card_ready) preclocks=preclocks+1;
            if(mosi!==1) $fatal(1,"SD high-CS clocks must use MOSI=1");
        end else begin
            rxshift={rxshift[6:0],mosi};
            if(bitpos==7) begin
                received=rxshift;bitpos=0;
                if(cmdpos==0) begin
                    if(received[7:6]==2'b01) begin packet[0]=received;cmdpos=1;end
                end else begin
                    packet[cmdpos]=received;
                    if(cmdpos==5) begin
                        cmdpos=0;arg={packet[1],packet[2],packet[3],packet[4]};
                        // SPI spec 5.1.9.1 permits rejection of commands during
                        // a read (except CMD12). Do not mistake queued data for R1.
                        if(KEEP_READ_ON_DESELECT && read_pending) begin
                            enqueue(8'h04);
                        end else case(packet[0])
                            8'h40: begin
                                if(preclocks<74 || arg!=0 || received!=8'h95) $fatal(1,"CMD0 preamble/argument/CRC");
                                card_ready=0;app_cmd=0;attempts=0;
                                // Fault 15 reproduces the board's CMD0 R1=00 diagnostic.
                                if(fault!=6) begin enqueue(8'hff);enqueue(fault==15?8'h00:fault==11?8'h04:8'h01);end
                            end
                            8'h48: begin
                                if(arg!=32'h1aa || received!=8'h87) $fatal(1,"CMD8 argument/CRC");
                                if(card_type==0) enqueue(5);
                                else begin enqueue(1);enqueue(0);enqueue(0);enqueue(1);enqueue(fault==7?8'hab:8'haa);end
                            end
                            8'h77: begin
                                if(arg!=0) $fatal(1,"CMD55 argument");
                                app_cmd=1;enqueue(1);
                            end
                            8'h69: begin
                                if(!app_cmd || arg!=(card_type==0?0:32'h40000000)) $fatal(1,"ACMD41 missing CMD55/HCS");
                                app_cmd=0;
                                if(attempts<2 || fault==9) begin attempts=attempts+1;enqueue(1);end
                                else begin card_ready=1;enqueue(0);end
                            end
                            8'h7a: begin
                                enqueue(0);enqueue(fault==8?8'h00:(card_type==2?8'hc0:8'h80));
                                enqueue(8'hff);enqueue(8'h80);enqueue(0);
                            end
                            8'h50: begin
                                if(card_type==2 || arg!=512) $fatal(1,"CMD16 must only set SDSC block length");
                                enqueue(0);
                            end
                            8'h51: begin
                                if(!card_ready) $fatal(1,"CMD17 before ready");
                                read_pending=1;
                                command17_count=command17_count+1;
                                if(card_type!=2 && arg[8:0]!=0) $fatal(1,"SDSC byte address alignment");
                                sector=card_type==2?arg:arg>>9;
                                if(fault==1) begin end // no response
                                else if(fault==2) enqueue(4);
                                else begin
                                    enqueue(8'hff);enqueue(0);
                                    if(fault==3) begin end // no data token
                                    else if(fault==5) enqueue(8'h0d);
                                    else begin
                                        if(fault==4) for(i=0;i<7;i=i+1) enqueue(8'hff);
                                        if(fault==10) for(i=0;i<6000;i=i+1) enqueue(8'hff);
                                        enqueue(8'hfe);
                                        // Fault 12: catalog is good, first load header is corrupt.
                                        crc=0;
                                        for(i=0;i<512;i=i+1) begin
                                            payload=fault==12 && command17_count==5?8'hff:
                                                BMP_HEADERS?bmp_byte(sector,i):(i[7:0]^sector[7:0]);
                                            // Card CRC is calculated before a simulated wire bit error.
                                            crc=crc ^ {payload,8'h00};
                                            for(crc_bit=0;crc_bit<8;crc_bit=crc_bit+1)
                                                crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
                                            enqueue(fault==14 && i==200?payload^8'h01:payload);
                                        end
                                        enqueue(crc[15:8]);enqueue(fault==13?crc[7:0]^8'h01:crc[7:0]);
                                    end
                                end
                            end
                            default: $fatal(1,"Unknown command %h",packet[0]);
                        endcase
                    end else cmdpos=cmdpos+1;
                end
            end else bitpos=bitpos+1;
        end
    end
    always @(negedge sck) if(!rst && !cs) begin
        if(bitpos==0) begin
            if(rd<wr) begin txshift=response[rd];rd=rd+1;end
            else begin txshift=8'hff;read_pending=0;end
        end else txshift={txshift[6:0],1'b1};
        miso=txshift[7];
    end
endmodule
