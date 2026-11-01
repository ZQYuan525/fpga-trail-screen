`timescale 1ns/1ps
module tb_sd_protocol;
    reg clk=0,rst=0,req=0;
    always #5 clk=~clk;
    reg [1:0] card_type=2;
    reg [3:0] fault=0;
    reg [31:0] address=32'h12345;
    wire init_done,block_addr,init_sel,sec_sel,istart,sstart,busy,done;
    wire [7:0] itx,stx,rx,data;
    wire [3:0] init_error;
    wire cs,sck,mosi,miso,sbusy,valid,ending,error;
    wire [11:0] read_diagnostic;
    integer cmd17,preclocks,received=0,previous,kind,mode;
    sd_init_seq #(.POWER_WAIT(10),.R1_BYTES(8),.INIT_RETRIES(8),.RECOVERY_BYTES(8)) init(
        .clk(clk),.rst(rst),.spi_start(istart),.spi_byte(itx),.spi_busy(busy),.spi_done(done),.rx_byte(rx),
        .selected(init_sel),.init_done(init_done),.init_busy(),.block_addressing(block_addr),.err_code(init_error));
    sd_rw_sector #(.R1_BYTES(8),.RETRY_MAX(3),.TOKEN_TIMEOUT(8)) sector(
        .clk(clk),.rst(rst),.sec_read(req),.sec_addr(address),.block_addressing(block_addr),
        .sec_data(data),.sec_data_valid(valid),.sec_end(ending),.sec_error(error),.read_diagnostic(read_diagnostic),.busy(sbusy),.selected(sec_sel),
        .spi_start(sstart),.spi_byte(stx),.spi_busy(busy),.spi_done(done),.rx_byte(rx));
    sd_spi #(.DIV(2),.LOW_DIV(4)) spi(.clk(clk),.rst(rst),.selected(init_done?sec_sel:init_sel),.low_speed(!init_done),
        .spi_start(init_done?sstart:istart),.spi_byte(init_done?stx:itx),.spi_busy(busy),.spi_done(done),.rx_byte(rx),
        .sck(sck),.cs(cs),.mosi(mosi),.miso(miso));
    sd_card_model card(.rst(rst),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),.card_type(card_type),.fault(fault),
        .command17_count(cmd17),.preclocks(preclocks));
    always @(negedge clk) if(!rst && valid) begin
        if(data!==((received[7:0]^address[7:0]) ^ ((fault==14 && received==200)?8'h01:8'h00))) $fatal(1,"SD byte %0d=%h",received,data);
        received=received+1;
    end
    task read_sector(input integer scenario);
        begin
            @(negedge clk);fault=scenario;received=0;previous=cmd17;req=1;
            @(negedge clk);req=0;wait(ending);@(negedge clk);
            if(scenario==0 || scenario==4) begin
                if(error || received!=512 || cmd17-previous!=1) $fatal(1,"good sector/final token lost");
                if(read_diagnostic!=0) $fatal(1,"successful read must clear error detail");
            end else if(scenario==13 || scenario==14) begin
                if(!error || received!=512 || read_diagnostic!==12'h600 || cmd17-previous!=1)
                    $fatal(1,"corrupt sector must finish with CRC error and no implicit replay");
            end else begin
                if(!error || received!=0) $fatal(1,"SD failure not reported");
                if((scenario==1 || scenario==2) && cmd17-previous!=3) $fatal(1,"SD retry budget");
                case(scenario)
                    1:if(read_diagnostic!==12'h1ff) $fatal(1,"command timeout detail");
                    2:if(read_diagnostic!==12'h204) $fatal(1,"R1 error detail");
                    3:if(read_diagnostic!==12'h3ff) $fatal(1,"token timeout detail");
                    5:if(read_diagnostic!==12'h40d) $fatal(1,"bad token detail");
                endcase
            end
            repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        for(kind=0;kind<3;kind=kind+1) begin
            @(negedge clk);card_type=kind;rst=1;fault=0;
            repeat(8) @(negedge clk);rst=0;
            wait(init_done || init_error!=0);
            if(!init_done || block_addr!==(kind==2)) $fatal(1,"SD init/card type %0d",kind);
            read_sector(0);
            for(mode=1;mode<=5;mode=mode+1) begin read_sector(mode);read_sector(0);end
            read_sector(13);read_sector(0);read_sector(14);read_sector(0);
        end
        for(mode=6;mode<=9;mode=mode+1) begin
            @(negedge clk);rst=1;fault=mode;card_type=2;
            repeat(8) @(negedge clk);rst=0;
            wait(init_done || init_error!=0);
            if(init_done || init_error==0) $fatal(1,"bad initialization accepted mode=%0d",mode);
        end
        $display("PASS SD: mode0, full commands/CRC/CS, SDv1/v2/SDSC/SDHC, retries, R1/token bounds, recovery");
        $finish;
    end
    initial begin #20000000;$fatal(1,"SD protocol watchdog");end
endmodule
