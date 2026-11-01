`timescale 1ns/1ps
// Card power is independent of FPGA reset. Exercise CS interruption at the wire.
module tb_sd_host_reset #(parameter DELAYED=0, BIT_OFFSETS=8);
    reg clk=0,rst=0,card_power_reset=0,req=0;
    always #5 clk=~clk;
    wire init_done,block_addr,init_sel,sec_sel,istart,sstart,busy,done;
    wire [7:0] itx,stx,rx,data;
    wire [3:0] init_error;
    wire [11:0] diagnostic;
    wire cs,sck,mosi,miso,sbusy,valid,ending,error;
    integer cmd17,preclocks,received=0,scenario,edge_offset,before_reads;
    reg check_data=0;
    sd_init_seq #(.POWER_WAIT(10),.R1_BYTES(8),.INIT_RETRIES(8)) init(
        .clk(clk),.rst(rst),.spi_start(istart),.spi_byte(itx),.spi_busy(busy),.spi_done(done),.rx_byte(rx),
        .selected(init_sel),.init_done(init_done),.init_busy(),.block_addressing(block_addr),
        .err_code(init_error),.command_diagnostic(diagnostic));
    sd_rw_sector #(.R1_BYTES(8),.RETRY_MAX(3),.TOKEN_TIMEOUT(6100)) sector(
        .clk(clk),.rst(rst),.sec_read(req),.sec_addr(32'h12345),.block_addressing(block_addr),
        .sec_data(data),.sec_data_valid(valid),.sec_end(ending),.sec_error(error),.read_diagnostic(),
        .busy(sbusy),.selected(sec_sel),.spi_start(sstart),.spi_byte(stx),
        .spi_busy(busy),.spi_done(done),.rx_byte(rx));
    sd_spi #(.DIV(2),.LOW_DIV(4)) spi(.clk(clk),.rst(rst),.selected(init_done?sec_sel:init_sel),.low_speed(!init_done),
        .spi_start(init_done?sstart:istart),.spi_byte(init_done?stx:itx),.spi_busy(busy),.spi_done(done),.rx_byte(rx),
        .sck(sck),.cs(cs),.mosi(mosi),.miso(miso));
    sd_card_model #(.KEEP_READ_ON_DESELECT(1)) card(.rst(card_power_reset),.cs(cs),.sck(sck),.mosi(mosi),
        .miso(miso),.card_type(2'd2),.fault(DELAYED?4'd10:4'd4),.command17_count(cmd17),.preclocks(preclocks));
    always @(negedge clk) if(!rst && check_data && valid) begin
        if(data!==(received[7:0]^8'h45)) $fatal(1,"post-reset payload mismatch at %0d",received);
        received=received+1;
    end
    task await_init;
        begin
            wait(init_done || init_error!=0);
            if(init_error!=0) $fatal(1,"host-only reset scenario=%0d edge=%0d failed: I=%h R=%h",scenario,edge_offset,init_error,diagnostic);
            if(!block_addr) $fatal(1,"SDHC addressing lost");
        end
    endtask
    task request_read;
        begin @(negedge clk);req=1;@(negedge clk);req=0;end
    endtask
    initial begin
        #1;rst=1;card_power_reset=1;
        repeat(8) @(negedge clk);card_power_reset=0;rst=0;
        scenario=-1;edge_offset=0;await_init;
        // Partial command, R1/token wait, early/middle/final payload, CRC.
        for(scenario=0;scenario<6;scenario=scenario+1) begin
            for(edge_offset=1;edge_offset<=BIT_OFFSETS;edge_offset=edge_offset+1) begin
                request_read;
                case(scenario)
                    0: wait(card.cmdpos==3);
                    1: wait(cmd17>before_reads && sector.state==3);
                    2: wait(sector.state==5 && sector.data_count==0);
                    3: wait(sector.state==5 && sector.data_count==253);
                    4: wait(sector.state==5 && sector.data_count==511);
                    5: wait(sector.state==5 && sector.data_count==513);
                endcase
                repeat(edge_offset) @(posedge sck);
                #1;rst=1; // Asynchronous interruption, including SCK high.
                repeat(8) @(negedge clk);rst=0;
                await_init;
                received=0;check_data=1;request_read;wait(ending);@(negedge clk);
                if(error || received!=512) $fatal(1,"post-reset sector/CRC failed");
                check_data=0;before_reads=cmd17;
                repeat(4) @(negedge clk);
            end
            $display("host-only reset scenario %0d: %0d bit offsets passed",scenario,BIT_OFFSETS);
        end
        $display("PASS sd_host_reset: %0d powered-card interruptions, delayed=%0d, reinit and checked sector/CRC",6*BIT_OFFSETS,DELAYED);$finish;
    end
    initial begin before_reads=0;#600_000_000;$fatal(1,"host reset watchdog");end
endmodule
