`timescale 1ns/1ps
// 1280x960 (3686454 B) first image, 60 pixel sectors after
// the header at SD_SPI_DIV=25/10/5/3; the full load is extrapolated from these.
module tb_load_latency_big;
    wire [3:0] done;
    load_latency_chain #(.DIV(25),.FIRST_ENTRY(0),.MAX_DATA_SECTORS(60)) c25(.finished(done[0]));
    load_latency_chain #(.DIV(10),.FIRST_ENTRY(0),.MAX_DATA_SECTORS(60)) c10(.finished(done[1]));
    load_latency_chain #(.DIV(5),.FIRST_ENTRY(0),.MAX_DATA_SECTORS(60)) c5(.finished(done[2]));
    load_latency_chain #(.DIV(3),.FIRST_ENTRY(0),.MAX_DATA_SECTORS(60)) c3(.finished(done[3]));
    initial begin wait(&done);$display("PASS load_latency_big");$finish;end
    initial begin #1_000_000_000;$fatal(1,"load_latency_big watchdog");end
endmodule
