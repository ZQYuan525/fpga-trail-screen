`timescale 1ns/1ps
module tb_sd_host_reset_delayed;
    // 6000 FF bytes before the token: idle-looking MISO must not end recovery early.
    tb_sd_host_reset #(.DELAYED(1),.BIT_OFFSETS(2)) test();
endmodule
