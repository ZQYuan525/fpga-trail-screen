`timescale 1ns/1ps
module tb_async_fifo;
    reg wc=0,rc=0,rst=1,we=0,re=0;
    always #5 wc=~wc;
    always #7 rc=~rc;
    reg [31:0] din=0;
    wire [31:0] dout;
    wire empty,full,rv,wrdy,rrdy;
    wire [9:0] ru,wu;
    reg [31:0] expected[0:20000];
    integer writes=0,reads=0,i;
    reg random_read=0;
    async_fifo d(.wr_clk(wc),.rd_clk(rc),.rst(rst),.wr_en(we),.wr_data(din),
        .rd_data(dout),.rd_en(re),.empty(empty),.full(full),.rd_used(ru),.wr_used(wu),
        .rd_valid(rv),.wr_ready(wrdy),.rd_ready(rrdy));
    always @(posedge wc) if(!rst && we && !full) begin
        expected[writes]=din;writes=writes+1;
    end
    always @(negedge rc) begin
        if(!rst && rv) begin
            if(reads>=writes || dout!==expected[reads])
                $fatal(1,"FIFO order at %0d: %h expected %h",reads,dout,expected[reads]);
            reads=reads+1;
        end
        if(random_read) re=($random & 3)!=0;
    end
    task reset_fifo;
        begin
            rst=1;we=0;re=0;random_read=0;
            repeat(8) @(negedge wc);
            rst=0;wait(wrdy && rrdy);repeat(8) @(negedge wc);
            writes=0;reads=0;
            if(!empty || ru!=0 || wu!=0) $fatal(1,"FIFO reset empty=%b ru=%h wu=%h ready=%b%b",empty,ru,wu,wrdy,rrdy);
        end
    endtask
    initial begin
        reset_fifo;
        for(i=0;i<512;i=i+1) begin @(negedge wc);we=1;din=i;end
        @(negedge wc);we=0;repeat(16) @(negedge wc);
        $display("FIFO capacity writes=%0d full=%b wrused=%0d rdused=%0d",writes,full,wu,ru);
        if(writes!=512 || !full || wu!=512 || ru!=512) $fatal(1,"FIFO must hold exactly 512");
        we=1;din=32'hbad;repeat(8) @(negedge wc);we=0;
        if(writes!=512) $fatal(1,"full write accepted");
        @(negedge rc);re=1;wait(reads==512);repeat(12) @(negedge rc);re=0;
        if(reads!=writes || !empty) $fatal(1,"empty read accepted");
        reset_fifo;
        random_read=1;
        for(i=0;i<8000;i=i+1) begin @(negedge wc);we=($random & 3)!=0;din=i^32'h12340000;end
        @(negedge wc);we=0;random_read=0;
        @(negedge rc);re=1;wait(reads==writes);repeat(12) @(negedge rc);re=0;
        if(!empty) $fatal(1,"random drain");
        // Reset with buffered words, then verify an unrelated clean sequence.
        for(i=0;i<40;i=i+1) begin @(negedge wc);we=1;din=i;end
        reset_fifo;
        for(i=0;i<20;i=i+1) begin @(negedge wc);we=1;din=i+9000;end
        @(negedge wc);we=0;repeat(8) @(negedge rc);re=1;
        wait(reads==20);repeat(10) @(negedge rc);
        if(reads!=writes) $fatal(1,"reset recovery");
        $display("PASS FIFO vendor model: capacity, full/empty, multiple wraps, asynchronous traffic, reset");
        $finish;
    end
    initial begin #2000000;$fatal(1,"FIFO watchdog");end
endmodule
