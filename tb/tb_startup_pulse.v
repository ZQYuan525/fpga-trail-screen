`timescale 1ns/1ps
module tb_startup_pulse;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    wire p0,p1,p7,p8,p17,pdefault;
    startup_pulse #(.CNT_MAX(0)) a(.clk(clk),.rst(rst),.o_pulse(p0));
    startup_pulse #(.CNT_MAX(1)) b(.clk(clk),.rst(rst),.o_pulse(p1));
    startup_pulse #(.CNT_MAX(7)) c(.clk(clk),.rst(rst),.o_pulse(p7));
    startup_pulse #(.CNT_MAX(8)) d(.clk(clk),.rst(rst),.o_pulse(p8));
    startup_pulse #(.CNT_MAX(17)) e(.clk(clk),.rst(rst),.o_pulse(p17));
    startup_pulse f(.clk(clk),.rst(rst),.o_pulse(pdefault));
    integer cycle,run;
    initial begin
        for(run=0;run<2;run=run+1) begin
            rst=1;repeat(3) @(negedge clk);rst=0;
            for(cycle=1;cycle<=100010;cycle=cycle+1) begin
                @(negedge clk);
                if(p0!==(cycle==1) || p1!==(cycle==2) || p7!==(cycle==8) ||
                   p8!==(cycle==9) || p17!==(cycle==18) || pdefault!==(cycle==100001))
                    $fatal(1,"startup delay changed run=%0d cycle=%0d",run,cycle);
            end
        end
        $display("PASS startup_pulse: exact CNT_MAX+1 delay, 0/1/power-of-two boundaries, production default and reset rearm");
        $finish;
    end
    initial begin #3000000;$fatal(1,"startup watchdog");end
endmodule
