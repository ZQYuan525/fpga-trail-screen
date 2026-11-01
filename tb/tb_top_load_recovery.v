`timescale 1ns/1ps
// Reproduce N:4, H:FFFF, no pixels: first load gets a corrupt sector after
// a successful catalog scan. Exercise production abort + synthetic-key wiring.
module tb_top_load_recovery;
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire cs,sck,mosi,miso;
    integer cmd17,preclocks,loads=0;
    reg [108:0] snapshot;
    top #(.ENABLE_FILESYSTEM(0),.ENABLE_PERSISTENCE(0),.SD_SPI_DIV(3)) dut(.clk(clk),.rst_n(rst_n),.key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(2'b00),
        .sd_ncs(cs),.sd_dclk(sck),.sd_mosi(mosi),.sd_miso(miso));
    sd_card_model #(.BMP_HEADERS(1)) card(.rst(!rst_n),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),
        .card_type(2'd2),.fault(4'd12),.command17_count(cmd17),.preclocks(preclocks));
    defparam dut.u_reset.LOCK_STABLE_CYCLES=8;
    defparam dut.u_init.POWER_WAIT=20;
    defparam dut.u_init.RETRY_WAIT_CYCLES=20; // ACMD41 pause is separate from POWER_WAIT.
    defparam dut.u_init.RECOVERY_BYTES=8; // Cold-card fixture; warm reset covered by sd_host_reset.
    defparam dut.u_spi.LOW_DIV=4;
    defparam dut.u_recovery.ABORT_TIME_CYCLES=120;
    defparam dut.u_recovery.PRESS_TIME_CYCLES=25;
    defparam dut.u_recovery.SESSION_WINDOW_CYCLES=2_000_000;
    always @(negedge dut.clk_sd) if(!dut.rst_sd) begin
        if(dut.load_start) loads=loads+1;
        if(dut.u_recovery.src_rst) $fatal(1,"load failure must use abort, not init reset");
    end
    initial begin
        repeat(20) @(negedge clk);rst_n=1;
        wait(dut.player_error===1);repeat(4) @(negedge dut.clk_sd);
        if(cmd17!=5 || loads!=1 || dut.u_bmp.signature!==16'hffff || dut.init_error!==0 || dut.found_total!==4)
            $fatal(1,"did not reproduce scanned catalog followed by bad load header");
        snapshot=dut.diagnostics_sd;
        wait(dut.write_req===1);@(negedge dut.clk_sd);
        if(cmd17!=6 || loads!=2 || dut.u_bmp.signature!==16'h4d42 || dut.load_sector!==0 ||
           dut.player_error!==0 || dut.u_recovery.attempts!==1 || dut.diagnostics_sd!==snapshot)
            $fatal(1,"abort/key/reload failed loads=%0d CMD17=%0d",loads,cmd17);
        $display("PASS top_load_recovery: first-load FFFF, real abort handshake, same-image retry accepted");
        $finish;
    end
    initial begin #4_000_000;$fatal(1,"load recovery watchdog player=%0d bmp=%0d recovery=%0d attempts=%0d loads=%0d",dut.u_player.state,dut.u_bmp.state,dut.u_recovery.state,dut.u_recovery.attempts,loads);end
endmodule
