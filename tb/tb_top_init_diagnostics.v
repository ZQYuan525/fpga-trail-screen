`timescale 1ns/1ps
module tb_top_init_diagnostics;
    reg clk=0,rst_n=0;always #10 clk=~clk;
    reg [3:0] fault=11;
    wire cs,sck,mosi,miso;
    integer cmd17,preclocks,scenario;
    reg [11:0] expected;
    top #(.ENABLE_PERSISTENCE(0)) dut(.clk(clk),.rst_n(rst_n),.key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(2'b00),
        .sd_ncs(cs),.sd_dclk(sck),.sd_mosi(mosi),.sd_miso(miso));
    sd_card_model card(.rst(!rst_n),.cs(cs),.sck(sck),.mosi(mosi),.miso(miso),
        .card_type(2'd2),.fault(fault),.command17_count(cmd17),.preclocks(preclocks));
    defparam dut.u_reset.LOCK_STABLE_CYCLES=8;
    defparam dut.u_init.POWER_WAIT=20;
    defparam dut.u_init.RETRY_WAIT_CYCLES=20; // ACMD41 pause is separate from POWER_WAIT.
    defparam dut.u_init.RECOVERY_BYTES=8; // Cold-card/error injection; warm reset has its own wire-level bench.
    defparam dut.u_init.R1_BYTES=16;
    defparam dut.u_init.INIT_RETRIES=4;
    defparam dut.u_spi.LOW_DIV=4;
    defparam dut.u_recovery.ABORT_TIME_CYCLES=120;
    defparam dut.u_recovery.INIT_HOLD_CYCLES=50;
    initial begin
        for(scenario=0;scenario<6;scenario=scenario+1) begin
            rst_n=0;
            case(scenario)
                0:begin fault=11;expected=12'h104;end
                1:begin fault=6;expected=12'h1ff;end
                2:begin fault=7;expected=12'h201;end
                3:begin fault=8;expected=12'h500;end
                4:begin fault=9;expected=12'h401;end
                5:begin fault=15;expected=12'h100;end
            endcase
            repeat(20) @(negedge clk);rst_n=1;
            wait(dut.init_error!=0);
            repeat(4) @(negedge dut.clk_sd);
            if(dut.init_diagnostic!==expected || dut.diagnostics_sd[107:96]!==expected ||
               dut.diagnostics_sd[108]!==1 || cmd17!=0)
                $fatal(1,"wrong command/R1 snapshot scenario=%0d got=%h expected=%h",scenario,dut.diagnostics_sd[107:96],expected);
            if(scenario==5 && (dut.init_error!==2 || dut.status_sd!==4'hf || dut.fs_mounted || dut.fs_error!=0))
                $fatal(1,"CMD0 R1=00 must report I:2/E:F before FAT mounting");
            wait(dut.u_recovery.src_rst===1);
            repeat(4) @(negedge dut.clk_sd);
            if(dut.init_diagnostic!==0 || dut.diagnostics_sd[107:96]!==expected)
                $fatal(1,"source reset must clear live diagnostic, preserve first failure");
        end
        // Keep R1=00 asserted: the real top must exhaust its three source retries,
        // without reading any sectors or masking the failed initialization.
        wait(dut.u_recovery.failed===1);
        repeat(10) @(negedge dut.clk_sd);
        if(dut.u_recovery.attempts!==3 || dut.sd_init_done!==0 || cmd17!=0 ||
           dut.diagnostics_sd[107:96]!==12'h100 || dut.init_error!==2)
            $fatal(1,"persistent CMD0 R1=00 bypassed retry bound or lost first diagnosis");
        // A clean card response after external reset lets the same RTL initialize.
        rst_n=0;fault=0;repeat(20) @(negedge clk);rst_n=1;
        wait(dut.sd_init_done===1);
        if(dut.init_error!=0 || dut.u_recovery.failed || dut.u_recovery.attempts!=0 || dut.diagnostics_sd!==0)
            $fatal(1,"normal CMD0 response after reset did not restore initialization");
        $display("PASS top_init_diagnostics: CMD0/8/41/58 R1, timeout, snapshot, CMD0=00 rejection/retry exhaustion/reset recovery");
        $finish;
    end
    initial begin #1_000_000;$fatal(1,"init diagnostic watchdog");end
endmodule
