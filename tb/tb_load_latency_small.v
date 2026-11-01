`timescale 1ns/1ps
// Complete 201x101 (61058 B) first-image load at
// SD_SPI_DIV=25/10/5/3, plus DIV=25 with 25 extra read-access (Nac) bytes.
module tb_load_latency_small;
    wire [4:0] done;
    load_latency_chain #(.DIV(25),.FIRST_ENTRY(2),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c25(.finished(done[0]));
    load_latency_chain #(.DIV(10),.FIRST_ENTRY(2),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c10(.finished(done[1]));
    load_latency_chain #(.DIV(5),.FIRST_ENTRY(2),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c5(.finished(done[2]));
    load_latency_chain #(.DIV(3),.FIRST_ENTRY(2),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c3(.finished(done[3]));
    load_latency_chain #(.DIV(25),.FIRST_ENTRY(2),.NAC_BYTES(25),.EXP_W(201),.EXP_H(101),.EXP_SECTORS(120)) c25n(.finished(done[4]));
    initial begin wait(&done);$display("PASS load_latency_small");$finish;end
    initial begin #2_000_000_000;$fatal(1,"load_latency_small watchdog");end
endmodule
