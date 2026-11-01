`timescale 1ns/1ps
// 2 MHz (DIV=25) wrapper of the latency breakdown measurement.
module tb_latency_breakdown_2m;
    tb_latency_breakdown #(.DIV(25)) u();
endmodule
