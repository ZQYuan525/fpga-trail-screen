`timescale 1ns/1ps
// media_recovery contract: on error wait the abort window, press+release the
// synthetic key, success clears the budget, exhaustion goes sticky DEAD.
module tb_media_recovery;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg media_error=0,display_valid=0,init_error=0;
    reg load_success=0,progress=0;
    wire key_retry,src_rst;
    wire wire_failed;
    wire [1:0] attempts;

    media_recovery #(.CLK_FREQ_HZ(1000),.MAX_ATTEMPTS(3),
        .ABORT_TIME_CYCLES(120),.PRESS_TIME_CYCLES(25),.INIT_HOLD_CYCLES(50),
        .SESSION_WINDOW_CYCLES(600)) dut(
        .clk(clk),.rst(rst),.media_error(media_error),.init_error(init_error),
        .display_valid(display_valid),
        .load_success(load_success),.progress(progress),
        .key_retry(key_retry),.src_rst(src_rst),.attempts(attempts),.failed(wire_failed));

    integer errors=0;
    task step(input integer n); begin repeat(n) @(negedge clk); end endtask

    // one full retry: abort window -> 25-cycle low press -> release
    task do_retry(input [1:0] exp_att);
        begin
            step(2);
            wait(key_retry===1'b0);              // press begins after abort window
            if(attempts!==exp_att) begin errors=errors+1;$display("FAIL attempt# got %0d exp %0d",attempts,exp_att);end
            repeat(20) @(negedge clk);
            if(key_retry!==1'b0) begin errors=errors+1;$display("FAIL press released early");end
            wait(key_retry===1'b1);              // release
            @(negedge clk);
        end
    endtask

    initial begin
        #11;rst=0;step(2);
        if(key_retry!==1'b1||wire_failed!==1'b0) begin errors=errors+1;$display("FAIL idle state");end

        // T1: failure -> retry #1 -> display -> success clears budget
        media_error=1;step(2);
        do_retry(3'd1);
        media_error=0;step(10);
        display_valid=1;load_success=1;step(2);load_success=0;
        if(attempts!==0||wire_failed!==1'b0) begin errors=errors+1;$display("FAIL success clear");end
        display_valid=0;step(2);

        // T2: three failures in a row (budget was cleared by T1) -> DEAD
        media_error=1;step(2);
        do_retry(3'd1);            // error still high: guard expires -> next
        step(100);
        do_retry(3'd2);
        step(100);
        do_retry(3'd3);
        step(120);                 // error persists past window -> exhaust
        if(!wire_failed) begin errors=errors+1;$display("FAIL expected DEAD");end
        media_error=0;step(20);
        if(!wire_failed) begin errors=errors+1;$display("FAIL DEAD must be sticky");end

        // T3: no display ever (silent stall after retry) must exhaust too
        rst=1;repeat(4) @(negedge clk);rst=0;step(2);
        if(wire_failed||attempts!==0) begin errors=errors+1;$display("FAIL reset state");end
        step(610); do_retry(3'd1);   // boot window timeout (no error) -> retry
        step(610); do_retry(3'd2);
        step(610); do_retry(3'd3);
        step(610);
        if(!wire_failed) begin errors=errors+1;$display("FAIL silent stall must exhaust");end

        // T4: init failure -> src reset pulse (200 ms settle + 1 ms hold), then success
        rst=1;repeat(4) @(negedge clk);rst=0;step(2);
        init_error=1;step(2);
        wait(src_rst===1'b1);
        if(attempts!==3'd1) begin errors=errors+1;$display("FAIL init attempt got %0d",attempts);end
        repeat(2) @(negedge clk);
        if(!src_rst) begin errors=errors+1;$display("FAIL src_rst released early");end
        wait(src_rst===1'b0);
        init_error=0;                           // re-init succeeds: err_code cleared at reset release
        step(10);
        display_valid=1;load_success=1;step(1);load_success=0;step(1);
        if(attempts!==0||wire_failed!==1'b0) begin errors=errors+1;$display("FAIL init success clear");end
        display_valid=0;step(2);

        // T5: init failure exhausts budget -> DEAD (fresh boot, as in real HW)
        rst=1;repeat(4) @(negedge clk);rst=0;step(2);
        if(wire_failed||attempts!==0) begin errors=errors+1;$display("FAIL t5 reset state");end
        init_error=1;step(2);
        repeat(3) begin wait(src_rst===1'b1); wait(src_rst===1'b0); end
        step(10);
        if(!wire_failed) begin errors=errors+1;$display("FAIL init exhaust");end
        init_error=0;step(10);
        if(!wire_failed) begin errors=errors+1;$display("FAIL init DEAD sticky");end

        // T6: an old displayed frame is NOT evidence that a retry succeeded.
        rst=1;step(4);rst=0;display_valid=1;step(4);media_error=1;
        do_retry(1);step(100);do_retry(2);step(100);do_retry(3);step(120);
        if(!wire_failed || attempts!=3) $fatal(1,"old display reset retry budget");

        // T7: a long but progressing catalog scan must not consume retry budget.
        rst=1;display_valid=0;media_error=0;step(4);rst=0;progress=1;step(1800);
        if(attempts!=0 || wire_failed || key_retry!=1) $fatal(1,"progressing scan retried");
        progress=0;

        if(errors==0) $display("PASS media_recovery: abort-wait/press-release/success-clear/exhaust/sticky-dead/window-stall");
        else $display("FAIL media_recovery (%0d errors)",errors);
        $finish;
    end
    initial begin #3_000_000;$fatal(1,"recovery watchdog");end
endmodule
