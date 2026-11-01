`timescale 1ns/1ps
module tb_media_recovery_equivalence;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg media_error=0,init_error=0,display_valid=0,load_success=0,progress=0;
    wire a_key,a_rst,a_fail,b_key,b_rst,b_fail;
    wire [1:0] a_attempts,b_attempts;
    media_recovery #(.CLK_FREQ_HZ(100),.ABORT_TIME_CYCLES(7),.PRESS_TIME_CYCLES(3),
        .INIT_HOLD_CYCLES(2),.SESSION_WINDOW_CYCLES(19)) a(
        .clk(clk),.rst(rst),.media_error(media_error),.init_error(init_error),.display_valid(display_valid),
        .load_success(load_success),.progress(progress),.key_retry(a_key),.src_rst(a_rst),.attempts(a_attempts),.failed(a_fail));
    media_recovery_reference #(.CLK_FREQ_HZ(100),.ABORT_TIME_CYCLES(7),.PRESS_TIME_CYCLES(3),
        .INIT_HOLD_CYCLES(2),.SESSION_WINDOW_CYCLES(19)) b(
        .clk(clk),.rst(rst),.media_error(media_error),.init_error(init_error),.display_valid(display_valid),
        .load_success(load_success),.progress(progress),.key_retry(b_key),.src_rst(b_rst),.attempts(b_attempts),.failed(b_fail));
    integer cycle,seed=32'h1c0ffee;
    reg [31:0] random_value;
    reg [7:0] visited=0;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(cycle=0;cycle<30000;cycle=cycle+1) begin
            @(negedge clk);
            if({a_key,a_rst,a_fail,a_attempts,a.state,a.ticks} !== {b_key,b_rst,b_fail,b_attempts,b.state,b.ticks})
                $fatal(1,"recovery cycle equivalence failed at %0d a=%0d/%0d b=%0d/%0d",cycle,a.state,a.ticks,b.state,b.ticks);
            visited[a.state]=1;
            random_value=$random(seed);
            rst=(cycle%151)==150;
            // Mix stable stalls with simultaneous event priorities and reset.
            if(cycle%127<64) begin media_error=0;init_error=0;display_valid=0;load_success=0;progress=0;end
            else begin
                media_error=random_value[0];init_error=random_value[4:1]==0;
                load_success=random_value[8:5]==0;display_valid=random_value[9];progress=random_value[11:10]==0;
            end
        end
        if(visited!==8'hff) $fatal(1,"recovery equivalence missed states %h",visited);
        $display("PASS media_recovery_equivalence: 30000 cycles, all states, exact counter/output/state equality to pre-optimization reference");
        $finish;
    end
endmodule
