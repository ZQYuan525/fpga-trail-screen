`timescale 1ns/1ps
// Cross-check: complete 640x480 first-image load at
// SD_SPI_DIV=5 and 3, compared against the 60-sector extrapolation.
module tb_load_latency_vga_full;
    wire [1:0] done;
    load_latency_chain #(.DIV(5),.FIRST_ENTRY(1),.EXP_W(640),.EXP_H(480),.EXP_SECTORS(1801)) c5(.finished(done[0]));
    load_latency_chain #(.DIV(3),.FIRST_ENTRY(1),.EXP_W(640),.EXP_H(480),.EXP_SECTORS(1801)) c3(.finished(done[1]));
    initial begin wait(&done);$display("PASS load_latency_vga_full");$finish;end
    initial begin #3.0e9;$fatal(1,"load_latency_vga_full watchdog");end
endmodule
