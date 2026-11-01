`timescale 1ns/1ps
module tb_spi_timing;
 reg clk=0,rst=1,start=0,low=1,selected=0;
 always #5 clk=~clk;
 wire busy,done,sck,cs,mosi;wire [7:0] rx;
 integer bitno,mode;time previous_edge;
 sd_spi dut(.clk(clk),.rst(rst),.selected(selected),.low_speed(low),.spi_start(start),.spi_byte(8'ha5),
 .spi_busy(busy),.spi_done(done),.rx_byte(rx),.sck(sck),.cs(cs),.mosi(mosi),.miso(1'b1));
 initial begin
 #37;rst=0;
 repeat(4) @(negedge clk);
 if(sck!==1) $fatal(1,"SCK must idle high after reset");
 for(mode=0;mode<2;mode=mode+1) begin
 @(negedge clk);low=mode==0;selected=mode!=0;start=1;
 @(negedge clk);start=0;wait(busy);
 for(bitno=7;bitno>=0;bitno=bitno-1) begin
 @(negedge sck);
 // Mode 3: each bit begins with a falling edge and the card samples
 // MOSI at the following rising edge, so MOSI is checked while stable.
 if(mosi!==((8'ha5>>bitno)&1'b1)) $fatal(1,"MOSI must be stable before the rising sample edge");
 if(cs!==!selected) $fatal(1,"CS ownership");
 previous_edge=$time;@(posedge sck);
 if(mosi!==((8'ha5>>bitno)&1'b1)) $fatal(1,"MOSI must not change at the rising sample edge");
 if($time-previous_edge!=(low?2500:30)) $fatal(1,"SPI half-period=%t",$time-previous_edge);
 end
 wait(done);@(negedge clk);
 if(rx!=8'hff || sck!==1) $fatal(1,"SPI byte/end state");
 repeat(8) @(negedge clk);
 if(cs!==!selected) $fatal(1,"CS toggled between bytes");
 if(mosi!==1'b1 || sck!==1) $fatal(1,"SPI idle state between bytes");
 end
 $display("PASS SPI timing: 200kHz init, 16.67MHz transfer, mode3 setup, transaction-owned CS");$finish;
 end
 initial begin #100000;$fatal(1,"SPI watchdog");end
endmodule
