`timescale 1ns/1ps
// 64 actual left-channel PCM samples -> r22sdf -> natural-order 32-bin display.
// Magnitude is |Re|+|Im| (not power/dB); complete results commit at frame_start.
// Each bin falls by at most a quarter per block (attack is immediate).
// Levels live in LUT RAM, not a 256-bit register bus: a work copy for the decay
// and three display banks (write / last complete block / shown this frame).
// rd_level is the shown bank at the previous clock's rd_bin, 0 while !valid.
module audio_spectrum(
    input wire clk,rst,sample_valid,input wire signed [23:0] sample,
    input wire frame_start,
    input wire [4:0] rd_bin,output wire [7:0] rd_level,
    output reg valid,overflow,
    output reg [31:0] blocks,dropped_samples
);
    localparam CAPTURE=0,SEND=1,WAIT_RESULT=2,PRIME=3;
    reg [1:0] state;
    reg signed [15:0] samples[0:63]; /* fehdl force_ram=1, ram_style="bram" */
    reg signed [15:0] sample_q;
    reg [5:0] capture_index,send_index,result_index;
    wire fft_valid;
    wire signed [15:0] re,im;
    wire [15:0] abs_re=re[15]?-re:re;
    wire [15:0] abs_im=im[15]?-im:im;
    wire [16:0] magnitude={1'b0,abs_re}+{1'b0,abs_im};
    wire [7:0] level=|magnitude[16:14]?8'd255:magnitude[13:6];
    wire [5:0] bin={result_index[0],result_index[1],result_index[2],result_index[3],result_index[4],result_index[5]};
    (* ram_style="dram" *) reg [7:0] work[0:31];
    (* ram_style="dram" *) reg [7:0] display[0:127];
    reg [7:0] work_q,display_q;
    // Bank 3 is unused. write_bank differs from ready_bank and shown_bank.
    reg [1:0] write_bank,ready_bank,shown_bank;
    reg pending_valid,have_prev;
    // One register stage between the FFT output and the decay compare.
    reg [4:0] bin_q;
    reg [7:0] level_q;
    reg write_q,last_q;
    // Before the first complete block the work copy reads as zero (reset value).
    wire [7:0] prev=have_prev?work_q:8'd0;
    wire [7:0] decayed=prev-(prev>>2);
    wire [7:0] next_level=level_q>decayed?level_q:decayed;
    wire [5:0] sample_address=state==SEND?send_index+6'd1:send_index;
    assign rd_level=valid?display_q:8'd0;
    always @(posedge clk) begin
        if(sample_valid && state==CAPTURE) samples[capture_index]<=sample[23:8];
        sample_q<=samples[sample_address];
        work_q<=work[bin[4:0]];
        if(write_q) begin work[bin_q]<=next_level;display[{write_bank,bin_q}]<=next_level;end
        display_q<=display[{shown_bank,rd_bin}];
    end
    FFT #(.WIDTH(16)) u_fft(.clock(clk),.reset(rst),.di_en(state==SEND),
        .di_re(sample_q),.di_im(16'd0),.do_en(fft_valid),.do_re(re),.do_im(im));
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=CAPTURE;capture_index<=0;send_index<=0;result_index<=0;
            write_bank<=0;ready_bank<=1;shown_bank<=1;pending_valid<=0;have_prev<=0;valid<=0;
            bin_q<=0;level_q<=0;write_q<=0;last_q<=0;
            overflow<=0;blocks<=0;dropped_samples<=0;
        end else begin
            if(frame_start) begin shown_bank<=ready_bank;valid<=pending_valid;end
            if(sample_valid) begin
                if(state==CAPTURE) begin
                    capture_index<=capture_index+1'b1;
                    if(capture_index==63) begin state<=PRIME;send_index<=0;result_index<=0;end
                end else begin overflow<=1;dropped_samples<=dropped_samples+1'b1;end
            end
            if(state==PRIME) state<=SEND;
            if(state==SEND) begin
                send_index<=send_index+1'b1;
                if(send_index==63) state<=WAIT_RESULT;
            end
            write_q<=fft_valid && !bin[5];last_q<=fft_valid && result_index==63;
            if(fft_valid) begin
                bin_q<=bin[4:0];level_q<=level;
                result_index<=result_index+1'b1;
                if(result_index==63) state<=CAPTURE;
            end
            // The block just written becomes ready; write next into the bank
            // that is neither ready nor shown (shown takes ready on frame_start).
            if(last_q) begin
                ready_bank<=write_bank;
                write_bank<=2'd3-write_bank-(frame_start?ready_bank:shown_bank);
                pending_valid<=1;have_prev<=1;blocks<=blocks+1'b1;
            end
        end
    end
endmodule
