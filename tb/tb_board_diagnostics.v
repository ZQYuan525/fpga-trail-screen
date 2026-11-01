`timescale 1ns/1ps
module tb_board_diagnostics;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg [3:0] status_code=0,init_error=0,bmp_state=0;
    reg [2:0] found_total=0;
    reg [15:0] flags=0;
    reg [11:0] read_diagnostic=0;
    reg sector_req=0,sector_valid=0,sector_error=0,load_start=0,pixel_accept=0;
    reg [31:0] sector_addr=0;
    reg [7:0] sector_data=0;
    wire [108:0] report;
    reg [108:0] saved;
    board_diagnostics dut(.*);
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    initial begin
        tick();rst=0;bmp_state=2;status_code=2;tick();
        sector_req=1;tick();sector_req=0;
        sector_valid=1;sector_data=8'h42;tick();sector_data=8'h4d;tick();
        sector_data=8'h99;tick();sector_valid=0;
        sector_error=1;tick();sector_error=0;
        found_total=4;load_start=1;tick();load_start=0;
        pixel_accept=1;repeat(7) tick();pixel_accept=0;
        sector_addr=32'h70a;bmp_state=4;repeat(2) tick();
        if(report!==0) $fatal(1,"diagnostics must remain hidden before first fault");
        // Error and decoder IDLE/E happen together: retain prior phase 4.
        flags=16'he608;status_code=14;bmp_state=14;read_diagnostic=12'h3ff;tick();
        saved={1'b1,12'h3ff,4'd0,4'd4,4'd4,16'hf608,32'h70a,16'h4d42,20'd7};
        // Inputs may change immediately after the first fault (or it may be
        // only one cycle). Delayed publication must preserve the entire bundle.
        if(report!==0) $fatal(1,"diagnostic pipeline latency");
        status_code=0;read_diagnostic=12'h123;flags=0;sector_addr=100;tick();
        if(report!==saved) $fatal(1,"first-fault report mismatch %h expected %h",report,saved);
        sector_addr=100;flags=0;init_error=3;sector_req=1;pixel_accept=1;
        repeat(4) tick();
        if(report!==saved) $fatal(1,"abort/retry must not overwrite first failure");
        rst=1;tick();rst=0;sector_req=0;pixel_accept=0;
        bmp_state=0;status_code=0;tick();
        if(report!==0) $fatal(1,"reset must clear first failure");
        init_error=1;status_code=15;found_total=0;sector_addr=0;tick();tick();
        if(!report[108] || report[95:92]!=1 || report[35:0]!=0 || report[80])
            $fatal(1,"init failure diagnostics or sticky sector reset");
        $display("PASS board_diagnostics: passive first-fault capture, signature, accepted pixels, sticky sector error, reset");
        $finish;
    end
    initial begin #10000;$fatal(1,"board diagnostics timeout");end
endmodule
