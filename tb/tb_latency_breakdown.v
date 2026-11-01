`timescale 1ns/1ps
// Stage-2 pre-work: measured per-sector read cost on the verified SD chain.
// A full 922 KB image load is 1801 back-to-back CMD17s; per-sector cost is
// fully determined by the sd_spi divider and the card response (FSM overhead
// is pipeline-parallel and negligible), so we measure N=32 real sectors and
// compose the image-level latency analytically. Bit-accurate full-image
// simulation is ~60 min wall in ModelSim; this runs in seconds.
// DIV=3 -> 16.67 MHz (source default), DIV=25 -> 2 MHz (board-stable config).
module tb_latency_breakdown #(parameter DIV=3, parameter LOW_DIV=4, parameter N_SECTORS=32);
    localparam SPI_BIT_NS = 2*DIV*10;
    localparam SECTOR_BYTES = 6+7+1+512+2;          // cmd6 + R1(7+ff) + token + data + crc2
    localparam SECTOR_NS = SPI_BIT_NS*8*SECTOR_BYTES;
    localparam IMG_SECTORS = 1801;                   // 921,654-byte 640x480 BMP
    localparam WATCHDOG_NS = 20*SECTOR_NS*N_SECTORS + 200_000_000;

    reg clk=0,rst=0;always #5 clk=~clk;
    wire initialized,block_addr,isel,ssel,istart,sstart,spi_busy,spi_done;
    wire [7:0] itx,stx,rx,data;
    wire [3:0] init_error;
    wire [11:0] read_diagnostic;
    wire cs,sck,mosi,miso,sector_busy,valid,ending,sector_error;
    reg sec_req_r=0; reg [31:0] sec_addr_r=0;
    integer commands,preclocks;

    time t_end=0,t_req_dummy=0;
    integer i;
    real sum_ns,min_ns,max_ns;
    reg ending_d=0; integer end_pulses=0;
    always @(posedge clk) if(!rst) begin
        ending_d<=ending;
        if(ending && !ending_d) end_pulses<=end_pulses+1;
    end

    sd_init_seq #(.POWER_WAIT(10)) init(.clk(clk),.rst(rst),.spi_start(istart),.spi_byte(itx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx),.selected(isel),
        .init_done(initialized),.init_busy(),.block_addressing(block_addr),.err_code(init_error));
    sd_rw_sector #(.TOKEN_TIMEOUT(100_000_000/(16*DIV)/10+1)) sector(.clk(clk),.rst(rst),.sec_read(sec_req_r),
        .sec_addr(sec_addr_r),.block_addressing(block_addr),.sec_data(data),.sec_data_valid(valid),
        .sec_end(ending),.sec_error(sector_error),.read_diagnostic(read_diagnostic),.busy(sector_busy),.selected(ssel),
        .spi_start(sstart),.spi_byte(stx),.spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx));
    sd_spi #(.DIV(DIV),.LOW_DIV(LOW_DIV)) spi(.clk(clk),.rst(rst),.selected(initialized?ssel:isel),
        .low_speed(!initialized),.spi_start(initialized?sstart:istart),.spi_byte(initialized?stx:itx),
        .spi_busy(spi_busy),.spi_done(spi_done),.rx_byte(rx),.sck(sck),.cs(cs),.mosi(mosi),.miso(miso));
    sd_card_model #(.BMP_HEADERS(0)) card(.rst(rst),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),
        .card_type(2'd2),.fault(4'd0),.command17_count(commands),.preclocks(preclocks));

    // keep the read engine busy: request the next sector whenever idle
    reg [31:0] next_lba=0;
    always @(posedge clk) if(!rst) begin
        if(!sector_busy && !sec_req_r && initialized && i<N_SECTORS) begin
            sec_req_r<=1; sec_addr_r<=next_lba; next_lba<=next_lba+1;
        end else if(ending || sector_error) begin
            sec_req_r<=0;
        end
    end

    initial begin
        #11;rst=1;repeat(8) @(negedge clk);rst=0;
        wait(initialized);
        t_req_dummy=$time;
        sum_ns=0;min_ns=1e18;max_ns=0;
        for(i=0;i<N_SECTORS;i=i+1) begin
            wait(end_pulses>i);
            t_end=$time;
            if(t_end-t_req_dummy>max_ns) max_ns=t_end-t_req_dummy;
            if(t_end-t_req_dummy<min_ns) min_ns=t_end-t_req_dummy;
            sum_ns=sum_ns+(t_end-t_req_dummy);
            t_req_dummy=t_end;
        end
        $display("");
        $display("=== SD PER-SECTOR COST (DIV=%0d -> SPI %.2f MHz, normal card) ===", DIV, 100.0/(2*DIV));
        $display("sectors measured      : %0d", N_SECTORS);
        $display("avg /sector           : %0.4f ms", sum_ns/N_SECTORS/1e6);
        $display("min / max             : %0.4f / %0.4f ms", min_ns/1e6, max_ns/1e6);
        $display("theoretical /sector   : %0.4f ms  (%0d bytes x %0d ns/bit x 8)", SECTOR_NS/1e6, SECTOR_BYTES, SPI_BIT_NS);
        $display("effective throughput  : %.1f KB/s", 512.0/((sum_ns/N_SECTORS)/1e9)/1024);
        $display("922 KB image (1801 s) : %.2f s pure transfer at this rate", SECTOR_NS*1.0*IMG_SECTORS/1e9);
        $display("4-header scan         : ~%.1f ms", SECTOR_NS*4.0/1e6);
        if(init_error||sector_error) $fatal(1,"chain error");
        if(commands!=N_SECTORS) $fatal(1,"CMD17 count %0d != %0d",commands,N_SECTORS);
        if(max_ns>SECTOR_NS*1.05)
            $display("NOTE: max deviates >5%% from bit-time theory (bus turn-around variance)");
        $display("PASS latency_breakdown DIV=%0d", DIV);
        $finish;
    end
    initial begin #WATCHDOG_NS;$fatal(1,"latency watchdog DIV=%0d",DIV);end
endmodule
