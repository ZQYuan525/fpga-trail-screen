`timescale 1ns/1ps
// Reads every word through the vendor BRAM32K model and compares it with the
// generator's hex dump, so the INIT_xx word order is checked, not assumed.
module tb_logo_rom;
    reg clk=0;reg [9:0] addr=0;
    wire [15:0] data;
    reg [15:0] expected[0:1023];
    integer n,ink;
    always #5 clk=~clk;
    logo_rom dut(.clk(clk),.addr(addr),.data(data));
    initial begin
        $readmemh("logo_rom.hex",expected);
        ink=0;
        for(n=0;n<1024;n=n+1) begin
            @(negedge clk);addr=n;@(negedge clk);
            if(data!==expected[n]) $fatal(1,"logo word %0d: %h expected %h",n,data,expected[n]);
            if(data!=0) ink=ink+1;
        end
        if(ink<200) $fatal(1,"logo ROM nearly empty (%0d words)",ink);
        $display("PASS logo_rom: 1024 words match generator, %0d non-plate words",ink);$finish;
    end
endmodule
