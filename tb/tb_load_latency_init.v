`timescale 1ns/1ps
// Production init timing (100 ms power/ACMD41 wait, 8192-byte
// 200 kHz drain) + complete 201x101 first-image load at SD_SPI_DIV=25.
module tb_load_latency_init;
    wire done;
    load_latency_chain #(.DIV(25),.FIRST_ENTRY(2),.REAL_INIT(1),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c25(.finished(done));
    initial begin wait(done);$display("PASS load_latency_init");$finish;end
    initial begin #3.0e9;$fatal(1,"load_latency_init watchdog");end
endmodule
