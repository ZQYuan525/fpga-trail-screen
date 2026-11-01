`timescale 1ns/1ps
module tb_axis_recovery;
 reg clk=0,rst=1,vs=0,de=0,ready=0;reg [23:0] rgb=0;
 always #5 clk=~clk;
 wire valid,user,last,overflow;wire [23:0] data;
 integer i,received=0;reg check_new=0;reg stalled=0;reg [25:0] held;
 rgb_to_axis #(.WIDTH(8),.HEIGHT(2),.DEPTH(32)) dut(
 .clk(clk),.rst(rst),.i_vs(vs),.i_de(de),.i_rgb(rgb),.i_ready(ready),
 .o_user(user),.o_valid(valid),.o_last(last),.o_data(data),.overflow(overflow));
 always @(posedge clk) if(!rst) begin
 if(stalled && (!valid || {user,last,data}!==held)) $fatal(1,"stalled AXIS payload lost");
 stalled=valid && !ready;held={user,last,data};
 if(check_new && valid && ready) begin
 if(data!==24'(received+100) || user!==(received==0) || last!==(received%8==7)) $fatal(1,"AXIS resync pixel=%0d data=%h user=%b last=%b",received,data,user,last);
 received=received+1;
 end
 end
 initial begin
 #31;rst=0;@(negedge clk);vs=1;@(negedge clk);vs=0;de=1;
 for(i=0;i<40;i=i+1) begin rgb=i;@(negedge clk);end
 de=0;if(!overflow) $fatal(1,"missing overflow indication");ready=1;
 wait(!valid);repeat(4) @(negedge clk);
 // Without a new VS, input remains suppressed.
 de=1;repeat(8) @(negedge clk);de=0;if(valid) $fatal(1,"partial frame admitted after overflow");
 check_new=1;vs=1;@(negedge clk);vs=0;repeat(3) @(negedge clk);
 for(i=0;i<16;i=i+1) begin de=1;rgb=i+100;@(negedge clk);if(i==7) begin de=0;repeat(4) @(negedge clk);end end
 de=0;wait(received==16);repeat(3) @(negedge clk);
 if(valid || !overflow) $fatal(1,"AXIS drain/sticky error");
 $display("PASS AXIS recovery: overflow, stable stalled payload, discard, VS resync, SOF/EOL");$finish;
 end
 initial begin #10000;$fatal(1,"AXIS watchdog");end
endmodule
