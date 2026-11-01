`timescale 1ns/1ps
// Real production top, PLL/HDMI/SDRAM/FIFO IP and pin-level SD card model.
// Shortened timers keep this a source-recovery test, not a full video test.
module tb_top_recovery #(parameter EXTENSIONS=1);
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [3:0] fault=0;
    reg [1:0] card_type=2;
    wire cs,sck,mosi,miso;
    integer cmd17,preclocks,resets,scans,scenario;
    reg monitor=0;
    reg [108:0] first_fault;
    top #(.ENABLE_EXTENSIONS(EXTENSIONS),.ENABLE_FILESYSTEM(0),.ENABLE_PERSISTENCE(0),.SD_SPI_DIV(3)) dut(
        .clk(clk),.rst_n(rst_n),.key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(2'b00),
        .sd_ncs(cs),.sd_dclk(sck),.sd_mosi(mosi),.sd_miso(miso));
    sd_card_model #(.BMP_HEADERS(1)) card(
        .rst(!rst_n),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),
        .card_type(card_type),.fault(fault),.command17_count(cmd17),.preclocks(preclocks));
    defparam dut.u_reset.LOCK_STABLE_CYCLES=8;
    defparam dut.u_init.POWER_WAIT=20;
    defparam dut.u_init.RETRY_WAIT_CYCLES=20; // ACMD41 pause is separate from POWER_WAIT.
    defparam dut.u_init.RECOVERY_BYTES=8; // Cold-card fixture; warm reset covered by sd_host_reset.
    defparam dut.u_init.R1_BYTES=16;
    defparam dut.u_init.INIT_RETRIES=4;
    defparam dut.u_spi.LOW_DIV=4;
    defparam dut.u_recovery.ABORT_TIME_CYCLES=120;
    defparam dut.u_recovery.INIT_HOLD_CYCLES=50;
    defparam dut.u_recovery.SESSION_WINDOW_CYCLES=2_000_000;

    always @(posedge dut.u_recovery.src_rst) if(monitor) resets=resets+1;
    always @(negedge dut.clk_sd) if(monitor && !dut.rst_sd) begin
        if(dut.scan_start) scans=scans+1;
        if(dut.u_recovery.src_rst) begin
            if(dut.u_init.rst!==1 || dut.u_sector.rst!==1 || dut.u_spi.rst!==1)
                $fatal(1,"source reset did not reach all three consumers");
            if(dut.u_player.rst!==0 || dut.u_bmp.rst!==0 || dut.u_recovery.rst!==0 ||
               dut.u_board_diag.rst!==0 || dut.rst_storage!==0)
                $fatal(1,"source retry reset escaped its boundary");
            if(dut.init_error!==0 || dut.sd_init_done!==0 || dut.sector_busy!==0 ||
               dut.spi_busy!==0 || cs!==1 || sck!==1 || mosi!==1)
                $fatal(1,"source retry did not clear error/busy or idle SPI pins");
        end
    end

    task boot(input [3:0] failure, input [1:0] kind);
        begin
            $display("top_recovery boot fault=%0d card=%0d at %0t",failure,kind,$time);
            monitor=0;rst_n=0;fault=failure;card_type=kind;
            repeat(20) @(negedge clk);
            resets=0;scans=0;rst_n=1;
            wait(dut.rst_sd===0);monitor=1;
        end
    endtask
    task await_retry;
        integer n;
        begin
            n=0;
            while(dut.u_recovery.src_rst!==1 && n<250) begin
                @(negedge dut.clk_sd);n=n+1;
            end
            if(dut.u_recovery.src_rst!==1) $fatal(1,"init error did not trigger source retry");
        end
    endtask
    task await_failure(input [3:0] expected_code);
        begin
            wait(dut.init_error!=0);
            repeat(3) @(negedge dut.clk_sd);
            if(dut.init_error!==expected_code || dut.sd_init_done!==0 || scans!=0 || cmd17!=0)
                $fatal(1,"init failure was not held ahead of scan code=%0d",dut.init_error);
            if(dut.diagnostics_sd[108]!==1) $fatal(1,"first fault was not captured");
            first_fault=dut.diagnostics_sd;
        end
    endtask
    task await_scan;
        integer n;
        begin
            n=0;
            while(dut.load_start!==1 && n<200_000) begin
                @(negedge dut.clk_sd);n=n+1;
            end
            if(dut.load_start!==1) $fatal(1,"first-image scan did not finish");
            @(negedge dut.clk_sd);
            if(scans!=1 || cmd17!=4 || dut.found_total!==4 || dut.load_sector!==0 ||
               dut.init_error!==0 || dut.sd_block!==(card_type==2))
                $fatal(1,"re-initialization did not resume real four-image scan");
        end
    endtask

    initial begin
        resets=0;scans=0;
        // Baseline: normal boot must not consume recovery budget.
        boot(0,2);await_scan();
        if(resets!=0 || dut.u_recovery.attempts!==0) $fatal(1,"healthy boot retried");
        // Lost CMD0 R1 and explicit bad CMD0 R1, both recovered without board reset.
        for(scenario=0;scenario<2;scenario=scenario+1) begin
            boot(scenario==0?6:11,scenario==0?2:1);
            await_failure(scenario==0?1:2);
            await_retry();
            @(negedge dut.clk_sd);fault=0;
            wait(dut.u_recovery.src_rst===0);
            await_scan();
            if(resets!=1 || dut.u_recovery.attempts!==1 || dut.u_recovery.failed!==0)
                $fatal(1,"retry budget did not survive source reset");
            if(dut.diagnostics_sd!==first_fault) $fatal(1,"source retry erased first fault");
        end
        // Persistent bad R1 must consume exactly three retries and stop.
        boot(11,2);await_failure(2);
        wait(dut.u_recovery.failed===1);
        repeat(1000) @(negedge dut.clk_sd);
        if(resets!=3 || dut.u_recovery.attempts!==3 || scans!=0 || cmd17!=0 ||
           dut.u_recovery.src_rst!==0 || dut.init_error!==2)
            $fatal(1,"persistent init failure did not stop at three retries");
        fault=0;repeat(1000) @(negedge dut.clk_sd);
        if(!dut.u_recovery.failed || resets!=3) $fatal(1,"DEAD was not sticky");
        // External reset clears DEAD and the first-fault snapshot.
        boot(0,2);await_scan();
        if(dut.u_recovery.failed || dut.u_recovery.attempts!==0 || resets!=0 || dut.diagnostics_sd!==0)
            $fatal(1,"manual reset did not restore clean boot");
        $display("PASS top_recovery extensions=%0d: real SPI faults, scan resumes, reset isolation, budget, diagnostics",EXTENSIONS);
        $finish;
    end
    initial begin #15_000_000;$fatal(1,"top recovery watchdog");end
endmodule
