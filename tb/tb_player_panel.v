`timescale 1ns/1ps
module tb_player_panel;
    reg clk=0,rst=1,menu=0,activity=0;
    always #5 clk=~clk;
    reg [3:0] status=0,image=3;
    reg [2:0] volume=4,selection=0;
    wire [5:0] sel;wire [7:0] data;
    integer i,seen=0;
    // SEG_ON_CYCLES defaults to SCAN_CYCLES/4 = 1: each digit is lit one clock per slot.
    // IDLE_PAGES=4: dark after 1200 clocks without key, menu or error.
    player_panel #(.CLK_HZ(1000),.SCAN_CYCLES(4),.PAGE_CYCLES(300),.IDLE_PAGES(4)) dut(
        .clk(clk),.rst(rst),.status(status),.image(image),.volume(volume),.selection(selection),.period(2'd3),.menu(menu),.activity(activity),
        .seg_sel(sel),.seg_data(data));
    task read_page(input integer kind);
        begin
            seen=0;
            repeat(30) begin
                @(negedge clk);
                // Physical left-to-right: seg_sel[0] is the leftmost used digit
                // (label), seg_sel[5] the rightmost (value units).
                case(sel)
                    6'b111110:begin seen=seen|32;if(data!=(kind==1?8'hc1:kind==3?8'h86:8'h8c)) $fatal(1,"page label");end
                    6'b011111:begin seen=seen|1;if(data!=(kind==0?8'hb0:kind==3?8'h8e:8'hc0)) $fatal(1,"page value");end
                    6'b111111:;
                    6'b101111,6'b110111,6'b111011,6'b111101:;
                    default:$fatal(1,"multiple digit selects active");
                endcase
            end
            if(seen!=33) $fatal(1,"incomplete scan");
        end
    endtask
    task expect_dark;
        begin
            repeat(30) begin
                @(negedge clk);
                if(sel!==6'b111111) $fatal(1,"panel lit while idle sel=%b",sel);
            end
        end
    endtask
    integer lit_slots;
    initial begin
        repeat(3) @(negedge clk);rst=0;read_page(0);
        menu=1;selection=6;repeat(2) @(negedge clk);read_page(1);
        selection=4;repeat(2) @(negedge clk);read_page(2);
        status=15;repeat(2) @(negedge clk);read_page(3);
        status=0;menu=0;wait(dut.page==1);repeat(2) @(negedge clk);read_page(1);
        wait(dut.page==2);repeat(2) @(negedge clk);read_page(2);
        // Dimming: one selected clock per 4-clock slot.
        lit_slots=0;
        repeat(240) begin @(negedge clk);if(sel!==6'b111111) lit_slots=lit_slots+1;end
        if(lit_slots<58 || lit_slots>62) $fatal(1,"digit duty lit=%0d of 240",lit_slots);
        // Idle blanking, then a key wakes it; an error wakes it too.
        wait(dut.idle_pages==4);repeat(2) @(negedge clk);expect_dark;
        activity=1;repeat(2) @(negedge clk);wait(dut.page_ticks==10);read_page(dut.page);
        activity=0;repeat(2) @(negedge clk);read_page(dut.page);
        wait(dut.idle_pages==4);repeat(2) @(negedge clk);expect_dark;
        status=15;repeat(2) @(negedge clk);read_page(3);
        $display("PASS player_panel: six-digit left-to-right scan, PIC/VOL/PRD rotation, menu page override, error priority, 1/4 digit duty, idle blanking with key/error wake");$finish;
    end
    initial begin #60000;$fatal(1,"panel timeout");end
endmodule
