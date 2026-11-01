`timescale 1ns/1ps
module tb_wav_player;
    reg clk=0,vc=0,rst=1,enable=0,tick=0,play=1;
    reg sd_clock_run=1,video_clock_run=1;
    always #5 if(sd_clock_run) clk=~clk;
    always #20 if(video_clock_run) vc=~vc;
    wire req,ready,underflow;wire [15:0] misses;wire [9:0] minimum;wire [31:0] address;wire [7:0] fault;
    wire signed [23:0] left,right;
    reg busy=0,valid=0,ending=0,error=0,service_pause=0;
    reg can_output;integer saved_misses;
    reg fast_ticks=0;
    reg [7:0] data=0;
    integer service=-1,lba=0,channels=2,rate=48000,samples=0,clock_count=0,expected=0;
    integer audio_offset=58,fmt_offset=26,junk_size=5,nsamples=256;
    integer boundary_case,reset_case;
    reg saw_full=0;
    reg bad_chunk=0;
    integer bad_riff=0,case_index;
    integer bad_magic=0; // 1: "RIFF" first byte wrong, 2: "WAVE" last byte wrong
    reg short_file=0;
    wire [31:0] size=audio_offset+nsamples*channels*2;
    wav_player dut(.clk(clk),.video_clk(vc),.rst(rst),.enable(enable),.file_size(short_file?32'd43:size),
        .req(req),.address(address),.busy(busy),.valid(valid),.ending(ending),.error(error),.data(data),
        .sample_tick(tick),.play(play),.left(left),.right(right),.ready(ready),.fault(fault),.underflow(underflow),.missed_samples(misses),.minimum_level(minimum));
    function [7:0] at(input integer p);
        integer value,n,component;
        begin
            at=0;
            case(p)
                0:at="R";1:at="I";2:at="F";3:at="F";8:at="W";9:at="A";10:at="V";11:at="E";
                12:at="J";13:at="U";14:at="N";15:at="K";
            endcase
            case(p-fmt_offset)
                0:at="f";1:at="m";2:at="t";3:at=" ";4:at=16;8:at=1;10:at=channels;
                20:at=channels*2;22:at=16;
                24:at="d";25:at="a";26:at="t";27:at="a";
            endcase
            if(p>=16 && p<=19) at=junk_size>>((p-16)*8);
            if(p>=4 && p<=7) begin
                case(bad_riff)
                    1:at=(size-7)>>((p-4)*8); // one byte beyond file extent
                    2:at=32'd35>>((p-4)*8);  // total RIFF extent below 44 bytes
                    3:at=8'hff;             // 0xffffffff + 8 needs the carry bit
                    4:at=(audio_offset-16)>>((p-4)*8); // RIFF ends at the data header
                    5:at=(audio_offset-13)>>((p-4)*8); // RIFF ends inside the data header
                    default:at=(size-8)>>((p-4)*8);
                endcase
            end
            if(bad_magic==1 && p==0) at="X";
            if(bad_magic==2 && p==11) at="X";
            if(p>=fmt_offset+12 && p<=fmt_offset+15) at=rate>>((p-fmt_offset-12)*8);
            if(p>=fmt_offset+16 && p<=fmt_offset+19) at=(rate*channels*2)>>((p-fmt_offset-16)*8);
            if(p>=audio_offset-4 && p<audio_offset) at=(size-audio_offset)>>((p-audio_offset+4)*8);
            if(bad_chunk && p>=audio_offset-4 && p<audio_offset) at=(size-audio_offset+1)>>((p-audio_offset+4)*8);
            if(p>=audio_offset) begin
                n=(p-audio_offset)/(channels*2);component=((p-audio_offset)/2)%channels;
                value=component==0?n+100:-n-200;
                at=value>>(((p-audio_offset)%2)*8);
            end
        end
    endfunction
    always @(negedge clk) begin
        valid=0;ending=0;
        if(rst) begin service=-1;busy=0;end
        else if(service>=0) begin
            if(service_pause) begin end
            else if(service<512) begin valid=1;data=at(lba*512+service);service=service+1;end
            else begin ending=1;busy=0;service=-1;end
        end else if(req) begin
            if(short_file) $fatal(1,"short WAV must be rejected before requesting any sector");
            if(address[31:28]!=4) $fatal(1,"WAV file handle");
            lba=address[27:0];service=0;busy=1;
        end
    end
    always @(negedge vc) begin
        if(rst) begin tick=0;clock_count=0;end
        else begin clock_count=clock_count+1;tick=clock_count%(fast_ticks?4:521)==0;end
    end
    always @(posedge clk) begin
        if(rst) saw_full<=0;
        else if(dut.full) saw_full<=1;
    end
    always @(posedge vc) if(!rst && tick && dut.started) begin
        can_output=dut.holding && dut.ready_sync[2];
        #1;
        if(!can_output) begin
            if(left!==0 || right!==0) $fatal(1,"underflow did not output silence");
        end else begin
        if(play) begin
            expected=samples%nsamples;
            if(left!==24'((expected+100)*256) || right!==24'((channels==1?expected+100:-expected-200)*256))
                $fatal(1,"WAV PCM sample=%0d left=%d right=%d",samples,left,right);
        end else if(left!=0 || right!=0) $fatal(1,"WAV mute");
        samples=samples+1;
        end
    end
    task boot(input integer ch,frequency);
        begin
            rst=1;enable=0;channels=ch;rate=frequency;samples=0;
            repeat(6) @(negedge clk);rst=0;enable=1;
        end
    endtask
    // Business state must hold reset while raw reset is asserted; the release
    // edge timing is not checked here.
    always @(posedge clk or posedge rst) begin
        #1;
        if(rst) begin
            if(dut.state!==0 || req!==0 || ready!==0 || fault!==0 ||
               dut.offset!==0 || dut.received!==0 || dut.push!==0 ||
               dut.riff_limit!==0)
                $fatal(1,"SD business escaped reset");
        end
        if(dut.push && !dut.wr_ready) $fatal(1,"WAV push before FIFO write ready");
    end
    always @(posedge vc or posedge rst) begin
        #1;
        if(rst) begin
            if(left!==0 || right!==0 || underflow!==0 || misses!==0 || minimum!==512 ||
               dut.pending!==0 || dut.holding!==0 || dut.started!==0 || dut.ready_sync!==0)
                $fatal(1,"VIDEO business escaped reset");
        end
        if(dut.pop && !dut.rd_ready) $fatal(1,"WAV pop before FIFO read ready");
    end
    task reset_during_stream(input integer phase_ns);
        begin
            // Assert between clock edges, and discard the old service session.
            @(negedge clk);#2;rst=1;samples=0;service_pause=0;
            #1;
            if(req!==0 || ready!==0 || left!==0 || right!==0 ||
               dut.pending!==0 || dut.holding!==0 || dut.started!==0 || misses!==0)
                $fatal(1,"mid-stream reset did not assert asynchronously");
            repeat(8) @(negedge vc);
            #(phase_ns);rst=0;
            wait(samples>=4);
            if(fault || underflow || !ready || misses!=0)
                $fatal(1,"mid-stream restart failed phase=%0d",phase_ns);
        end
    endtask
    initial begin
        boot(2,48000);wait(samples>=600);if(fault || underflow || !ready) $fatal(1,"stereo stream failed");
        boot(1,48000);wait(samples>=600);if(fault || underflow) $fatal(1,"mono stream failed");
        play=0;wait(samples>=650);
        rst=1;play=1;boot(2,48000);wait(samples>=100);
        service_pause=1;wait(misses>=3);@(negedge vc);
        if(!underflow || minimum!=0 || left!=0 || right!=0) $fatal(1,"starvation telemetry");
        play=0;saved_misses=misses;repeat(1200) @(negedge vc);
        if(misses!=saved_misses) $fatal(1,"muted gaps counted as misses");
        // Counter arithmetic only: accelerate ticks while supply is already
        // empty. No deposit/force of the counter; naturally cross FFFE/FFFF
        // and keep ticking beyond saturation. This is not a rate-budget test.
        play=1;fast_ticks=1;repeat(65540*4) @(negedge vc);
        if(misses!==16'hffff || !underflow || minimum!=0 || left!==0 || right!==0)
            $fatal(1,"U counter wrapped or starvation stopped being silent");
        $display("PASS WAV U saturation: >65535 actual empty ticks, no counter injection, sticky FFFF and silent output");
        fast_ticks=0;
        play=1;service_pause=0;wait(samples>=800);
        if(fault || !ready || misses!==16'hffff) $fatal(1,"starvation did not recover with saturated counter");
        // Cross 511/512 inside a sample, at data start, and inside headers.
        // Large odd JUNK skips a sector; looping jumps back into cached or
        // uncached sectors. Exact output checks above run for over two loops.
        for(boundary_case=0;boundary_case<4;boundary_case=boundary_case+1) begin
            rst=1;
            audio_offset=boundary_case==3?1026:510+2*boundary_case;
            fmt_offset=audio_offset-32;junk_size=audio_offset-53;nsamples=257;
            boot(boundary_case==2?1:2,48000);wait(samples>=600);
            if(fault || underflow || !ready || !saw_full)
                $fatal(1,"WAV boundary/backpressure case=%0d fault=%h full_seen=%b",boundary_case,fault,saw_full);
        end
        rst=1;audio_offset=58;fmt_offset=26;junk_size=5;nsamples=256;
        boot(2,48000);
        // Re-enter every relevant active phase. The existing PCM scoreboard
        // resets to sample zero, so stale/duplicated pre-reset frames fail.
        for(reset_case=0;reset_case<6;reset_case=reset_case+1) begin
            case(reset_case)
                0:wait(dut.state==2 && dut.received==100);
                1:wait(dut.state==6 && dut.sample_byte==1 && !dut.full);
                2:wait(dut.pending);
                3:wait(dut.started && dut.holding);
                4:wait(dut.started && dut.full);
                5:begin service_pause=1;wait(misses>=2);end
            endcase
            // 1/4/6/19/21/39 ns cover both sides of SD and VIDEO edges.
            reset_during_stream(reset_case==0?1:reset_case==1?4:reset_case==2?6:
                                reset_case==3?19:reset_case==4?21:39);
            $display("reset case %0d: exact restart from first sample PASS",reset_case);
        end
        // A stopped destination clock must not release its business state.
        // Keep raw reset long enough for both FIFO domains before releasing.
        for(reset_case=0;reset_case<2;reset_case=reset_case+1) begin
            @(negedge clk);#2;rst=1;samples=0;
            repeat(8) @(negedge vc);
            if(reset_case==0) begin @(negedge vc);video_clock_run=0;end
            else begin @(negedge clk);sd_clock_run=0;end
            #3;rst=0;#400;
            if(reset_case==0 && (dut.started!==0 || dut.pending!==0 || left!==0 || right!==0))
                $fatal(1,"stopped VIDEO clock released business reset");
            if(reset_case==1 && (dut.state!==0 || req!==0 || ready!==0))
                $fatal(1,"stopped SD clock released business reset");
            sd_clock_run=1;video_clock_run=1;
            wait(samples>=4);
            if(fault || underflow || misses!=0) $fatal(1,"stopped-clock restart failed");
        end
        $display("PASS WAV reset: six active phases, asynchronous assertion, stopped clocks, FIFO gating, clean PCM/telemetry restart");
        rst=1;play=1;boot(2,44100);wait(fault!=0);if(ready) $fatal(1,"unsupported format ready");
        bad_chunk=1;boot(2,48000);wait(fault!=0);if(fault!=4 || ready) $fatal(1,"odd data block escaped RIFF/file bounds");
        bad_chunk=0;error=1;boot(2,48000);wait(fault!=0);if(fault!=2 || ready) $fatal(1,"bad file sector was parsed");error=0;
        for(case_index=1;case_index<=3;case_index=case_index+1) begin
            bad_riff=case_index;boot(2,48000);wait(fault!=0);
            if(fault!=3 || ready) $fatal(1,"invalid RIFF extent accepted case=%0d fault=%h",case_index,fault);
        end
        // CHUNK stops at the first header byte at riff_end, not one byte later.
        for(case_index=4;case_index<=5;case_index=case_index+1) begin
            bad_riff=case_index;boot(2,48000);wait(fault!=0);
            if(fault!=4 || ready || dut.offset!==audio_offset-(case_index==4?8:5))
                $fatal(1,"chunk header beyond RIFF end case=%0d fault=%h offset=%0d",case_index,fault,dut.offset);
        end
        bad_riff=0;
        for(case_index=1;case_index<=2;case_index=case_index+1) begin
            bad_magic=case_index;boot(2,48000);wait(fault!=0);
            if(fault!=3 || ready) $fatal(1,"bad RIFF/WAVE magic accepted case=%0d fault=%h",case_index,fault);
        end
        bad_magic=0;
        short_file=1;boot(2,48000);wait(fault!=0);if(fault!=1 || ready || req) $fatal(1,"short WAV metadata accepted");
        $display("PASS wav_player: odd JUNK, PCM16 mono/stereo, offsets 510/512/514/1026, sector/header crossing, two loops, exact samples, FIFO full/resume, mute, starvation silence/counter/minimum/recovery, unsupported rate, bad RIFF/WAVE magic");$finish;
    end
    initial begin #160000000;$fatal(1,"WAV watchdog state=%d fault=%d",dut.state,fault);end
endmodule
