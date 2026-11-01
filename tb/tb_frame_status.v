`timescale 1ns/1ps
module tb_frame_status;
    reg clk=0,rst=1,ack=0,vs=0,de=0,enable=0;
    reg [1:0] memory_image=0;
    wire [1:0] image_index;wire valid;
    always #20 clk=~clk;
    frame_media_status dut(.clk(clk),.rst(rst),.read_ack(ack),.i_vs(vs),.i_de(de),
        .display_enable(enable),.memory_image(memory_image),.image_index(image_index),.image_valid(valid));
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task boundary;begin vs=1;tick(3);vs=0;tick(2);end endtask
    task response(input [1:0] image);
        begin memory_image=image;tick(10);ack=1;tick(4);ack=0;tick(4);end
    endtask
    initial begin
        tick(4);rst=0;boundary();response(0);de=1;tick(1);
        if(valid) $fatal(1,"unpublished image exposed");de=0;
        boundary();enable=1;response(2);
        if(valid) $fatal(1,"image committed before first pixel");de=1;tick(1);
        if(!valid || image_index!=2) $fatal(1,"first pixel metadata");
        de=0;response(3);de=1;tick(3); // line starts must not commit another image
        if(image_index!=2) $fatal(1,"midframe metadata change");de=0;
        boundary();de=1;tick(1);if(image_index!=3) $fatal(1,"pending frame adoption");de=0;
        // During a wipe the reader continues to report the old image ID.
        boundary();response(3);de=1;tick(1);if(image_index!=3) $fatal(1,"wipe image changed");de=0;
        boundary();enable=0;de=1;tick(1);if(valid) $fatal(1,"fault metadata valid");
        $display("PASS frame_status: bundled read-ack metadata, first-pixel commit, line immunity, empty/fault");$finish;
    end
    initial begin #100000;$fatal(1,"frame status timeout");end
endmodule
