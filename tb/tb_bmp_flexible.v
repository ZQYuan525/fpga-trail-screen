`timescale 1ns/1ps
module tb_bmp_flexible;
    reg clk=0,rst=1,start=0,abort_load=0,ack=0,ready_pixel=1;
    always #5 clk=~clk;
    wire ready,req,wreq,pv,done,error,orientation;
    wire [31:0] addr;wire [23:0] rgb;wire [15:0] width,height;
    reg [7:0] data=0;reg dv=0,ending=0,busy=0;
    integer sw=3,sh=2,off=54,negative=0,bad=0,service=-1,service_addr=0,pixels=0,cycle=0;
    bmp_decoder #(.FLEXIBLE_SIZE(1)) dut(.clk(clk),.rst(rst),.sd_init_done(1'b1),.ready(ready),
        .sd_sec_read(req),.sd_sec_addr(addr),.sd_sec_data(data),.sd_sec_data_valid(dv),.sd_sec_end(ending),
        .sd_sec_busy(busy),.sd_sec_error(1'b0),.bmp_width(16'd1280),.bmp_height(16'd960),
        .scan_start(1'b0),.scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
        .load_start(start),.load_abort(abort_load),.load_sector(32'd0),.write_req(wreq),.write_req_ack(ack),
        .px_wr_en(pv),.px_data(rgb),.px_ready(ready_pixel),.load_done(done),.load_error(error),.progress(),.state_code(),
        .source_width(width),.source_height(height),.source_top_down(orientation));
    function [23:0] pixel(input integer n);
        pixel={8'(n*7),8'(n*11),8'(n*19)};
    endfunction
    function [7:0] byte_at(input integer p);
        integer stride,relative,row,column,h;
        begin
            stride=((sw*3+3)/4)*4;byte_at=0;relative=p-off;row=relative/stride;column=relative%stride;
            h=negative?-sh:sh;
            if(relative>=0 && row<sh) begin
                if(column<sw*3) byte_at=pixel(row*sw+column/3)>>((column%3)*8);
                else byte_at=8'hde;
            end
            case(p)
                0:byte_at=bad?0:8'h42;1:byte_at=8'h4d;14:byte_at=40;26:byte_at=1;28:byte_at=24;
            endcase
            if(p>=2 && p<=5) byte_at=(off+stride*sh)>>((p-2)*8);
            if(p>=10 && p<=13) byte_at=off>>((p-10)*8);
            if(p>=18 && p<=21) byte_at=sw>>((p-18)*8);
            if(p>=22 && p<=25) byte_at=h>>((p-22)*8);
        end
    endfunction
    always @(negedge clk) begin
        cycle=cycle+1;ack=wreq;ready_pixel=cycle%7<4;dv=0;ending=0;
        if(service>=0) begin
            if(service<512) begin dv=1;data=byte_at(service_addr*512+service);service=service+1;end
            else begin ending=1;busy=0;service=-1;end
        end else if(req) begin busy=1;service_addr=addr;service=0;end
    end
    always @(posedge clk) if(!rst && pv && ready_pixel) begin
        if(rgb!==pixel(pixels)) $fatal(1,"BMP padding/row mismatch %0d %h",pixels,rgb);
        pixels=pixels+1;
    end
    task load_case(input integer w,h,topdown,offset,expect_error);
        begin
            wait(ready);@(negedge clk);sw=w;sh=h;negative=topdown;off=offset;pixels=0;start=1;
            @(negedge clk);start=0;wait(done);@(negedge clk);
            if(error!=expect_error || pixels!=(expect_error?0:w*h)) $fatal(1,"flexible BMP count/error %dx%d",w,h);
            if(!expect_error && (width!=w || height!=h || orientation!=topdown)) $fatal(1,"BMP metadata");
        end
    endtask
    initial begin
        #23;rst=0;load_case(3,2,0,54,0);load_case(3,2,1,700,0);
        load_case(1,1,0,511,0);load_case(13,9,1,54,0);
        load_case(1280,1,0,54,0);load_case(1,960,1,700,0);
        load_case(1281,2,0,54,1);load_case(3,961,0,54,1);load_case(0,1,0,54,1);
        bad=1;load_case(3,2,0,54,1);bad=0;load_case(7,3,0,700,0);
        $display("PASS flexible BMP: padding, positive/negative height, offset/sector boundaries, limits and recovery");$finish;
    end
    initial begin #3000000;$fatal(1,"flexible BMP timeout");end
endmodule
