`timescale 1ns/1ps
// Load-latency SDHC SPI model backed by a real FAT32 image file.
// Only the commands issued by sd_init_seq/sd_rw_sector are accepted.
// FIRST_ENTRY swaps root directory entry 0 with that entry (first image
// selection without copying the image). NAC_BYTES adds 0xFF bytes before
// the data token to model card read access time. Read-only: never writes.
module sd_image_card_model #(
    parameter IMAGE="../../media_20260919_173540/acceptance_fat32.img",
    parameter integer FIRST_ENTRY=0, NAC_BYTES=0, ACMD41_BUSY=2
)(
    input wire rst,cs,sck,mosi,output reg miso,
    output integer command17_count,output integer fat_reads,output integer data_reads,
    output integer preclocks,output reg [31:0] last_lba
);
    reg [7:0] rxshift,txshift,received;
    reg [7:0] packet[0:5],response[0:4095],block[0:511],boot[0:511],swap;
    integer bitpos,cmdpos,wr,rd,attempts,i,fd,status,crc_bit;
    reg app_cmd,card_ready;
    reg [31:0] arg,reserved,fat_end,dir_lba;
    reg [15:0] crc;
    task enqueue(input [7:0] value);
        begin response[wr]=value;wr=wr+1;end
    endtask
    task read_block(input [31:0] lba);
        begin
            status=$fseek(fd,lba*512,0);
            if(status!=0) $fatal(1,"image seek failed at LBA %0d",lba);
            status=$fread(block,fd,0,512);
            if(status!=512) $fatal(1,"image read failed at LBA %0d (%0d bytes)",lba,status);
        end
    endtask
    reg [8*512-1:0] path;
    initial begin
        path=IMAGE;
        if($value$plusargs("t08_image=%s",path)) $display("card image override: %0s",path);
        fd=$fopen(path,"rb");
        if(fd==0) $fatal(1,"cannot open card image %0s",path);
        read_block(0);
        for(i=0;i<512;i=i+1) boot[i]=block[i];
        if(boot[510]!=8'h55 || boot[511]!=8'haa || boot[11]!=0 || boot[12]!=2)
            $fatal(1,"card image LBA0 is not a 512-byte FAT32 boot sector");
        reserved={boot[15],boot[14]};
        fat_end=reserved+boot[16]*{boot[39],boot[38],boot[37],boot[36]};
        // prepare_media places the root directory (cluster 2) at the data start.
        dir_lba=fat_end;
    end
    always @(posedge rst) begin
        miso=1;rxshift=0;txshift=8'hff;bitpos=0;cmdpos=0;wr=0;rd=0;attempts=0;
        app_cmd=0;card_ready=0;command17_count=0;fat_reads=0;data_reads=0;preclocks=0;last_lba=0;
    end
    always @(negedge cs) if(!rst) begin rxshift=0;txshift=8'hff;miso=1;bitpos=0;cmdpos=0;wr=0;rd=0;end
    always @(posedge cs) if(!rst) begin
        if(cmdpos!=0) $fatal(1,"SD CS released before all six command bytes");
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
                        case(packet[0])
                            8'h40: begin
                                if(preclocks<74 || arg!=0 || received!=8'h95) $fatal(1,"CMD0 preamble/argument/CRC");
                                card_ready=0;app_cmd=0;attempts=0;enqueue(8'hff);enqueue(8'h01);
                            end
                            8'h48: begin
                                if(arg!=32'h1aa || received!=8'h87) $fatal(1,"CMD8 argument/CRC");
                                enqueue(1);enqueue(0);enqueue(0);enqueue(1);enqueue(8'haa);
                            end
                            8'h77: begin app_cmd=1;enqueue(card_ready?8'h00:8'h01);end
                            8'h69: begin
                                if(!app_cmd || arg!=32'h40000000) $fatal(1,"ACMD41 missing CMD55/HCS");
                                app_cmd=0;
                                if(attempts<ACMD41_BUSY) begin attempts=attempts+1;enqueue(1);end
                                else begin card_ready=1;enqueue(0);end
                            end
                            8'h7a: begin enqueue(0);enqueue(8'hc0);enqueue(8'hff);enqueue(8'h80);enqueue(0);end
                            8'h51: begin
                                if(!card_ready) $fatal(1,"CMD17 before ready");
                                command17_count=command17_count+1;last_lba=arg;
                                if(arg>=reserved && arg<fat_end) fat_reads=fat_reads+1;
                                else data_reads=data_reads+1;
                                read_block(arg);
                                if(FIRST_ENTRY!=0 && arg==dir_lba) for(i=0;i<32;i=i+1) begin
                                    swap=block[i];block[i]=block[FIRST_ENTRY*32+i];block[FIRST_ENTRY*32+i]=swap;
                                end
                                enqueue(8'hff);enqueue(0);
                                for(i=0;i<NAC_BYTES;i=i+1) enqueue(8'hff);
                                enqueue(8'hfe);crc=0;
                                for(i=0;i<512;i=i+1) begin
                                    crc=crc ^ {block[i],8'h00};
                                    for(crc_bit=0;crc_bit<8;crc_bit=crc_bit+1)
                                        crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
                                    enqueue(block[i]);
                                end
                                enqueue(crc[15:8]);enqueue(crc[7:0]);
                            end
                            default: $fatal(1,"Unexpected command %h",packet[0]);
                        endcase
                    end else cmdpos=cmdpos+1;
                end
            end else bitpos=bitpos+1;
        end
    end
    always @(negedge sck) if(!rst && !cs) begin
        if(bitpos==0) begin
            if(rd<wr) begin txshift=response[rd];rd=rd+1;end
            else txshift=8'hff;
        end else txshift={txshift[6:0],1'b1};
        miso=txshift[7];
    end
endmodule
