// Compatible 2M x 32 JEDEC SDR model; it is not an EM638325 silicon model.
module EG_PHY_SDRAM_2M_32 (
    input clk, ras_n, cas_n, we_n, input [10:0] addr, input [1:0] ba,
    inout [31:0] dq, input cs_n, dm0, dm1, dm2, dm3, cke
);
    parameter CLOCK_PAD_DELAY = 5;
    parameter MODEL_TAC = 5.5;
    wire device_clk;
    assign #(CLOCK_PAD_DELAY) device_clk = clk;
    mt48lc2m32b2 #(.tAC(MODEL_TAC)) memory (
        .Dq(dq), .Addr(addr), .Ba(ba), .Clk(device_clk), .Cke(cke),
        .Cs_n(cs_n), .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n),
        .Dqm({dm3, dm2, dm1, dm0})
    );
endmodule
