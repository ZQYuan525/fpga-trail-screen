`timescale 1ns/1ps
// PCM16, 48 kHz, mono/stereo RIFF/WAVE. Skips unknown chunks and odd padding.
// Reads verified file sectors through FAT service; sample FIFO crosses to HDMI.
module wav_player(
    input wire clk,video_clk,rst,enable,
    input wire [31:0] file_size,
    output reg req,output reg [31:0] address,
    input wire busy,valid,ending,error,input wire [7:0] data,
    input wire sample_tick,play,
    output reg signed [23:0] left,right,
    output reg ready,output reg [7:0] fault,
    output reg underflow,
    output reg [15:0] missed_samples,output reg [9:0] minimum_level
);
    localparam IDLE=0,FETCH=1,RECEIVE=2,RIFF=3,CHUNK=4,FORMAT=5,PCM=6,STOP=7,
        CHUNK_ADD=8,CHUNK_PAD=9,CHUNK_CHECK=10,RIFF_CHECK=11,CHUNK_DISPATCH=12,RIFF_RESUME=13,FILE_CHECK=14,FORMAT_CHECK=15,FORMAT_FINISH=16,RIFF_WAVE=17;
    reg [4:0] state,after_byte;
    (* ram_style="block" *) reg [7:0] bytes[0:511];
    reg [7:0] byte_ram_q,byte_q;
    reg [1:0] byte_wait;
    reg format_invalid;
    reg [9:0] received;
    reg [31:0] offset,loaded_sector,riff_end,chunk_end,chunk_size,chunk_id,data_start,data_last;
    reg [4:0] index;
    reg [31:0] word_shift;
    reg fmt_seen,stereo;
    reg [15:0] format_code,channels,block_align,bits;
    reg [31:0] rate,byte_rate;
    reg [1:0] sample_byte;
    reg [31:0] sample_word;
    reg push;
    wire full,empty,pop_valid,wr_ready,rd_ready;
    wire [31:0] popped;
    wire [9:0] used;
    reg pending,holding,started;
    reg [31:0] held;
    (* async_reg="true" *) reg [2:0] ready_sync;
    wire pop=!pending && !holding && !empty;
    wire [7:0] b=byte_q;
    wire [31:0] assembled={b,word_shift[31:8]};
    reg [32:0] next_chunk,padded_chunk;
    reg [32:0] riff_limit;
    reg [31:0] file_limit;
    reg bounds_invalid;
    reg chunk_format_invalid,chunk_data_invalid;
    async_fifo samples(.wr_clk(clk),.rd_clk(video_clk),.rst(rst),.wr_en(push),.wr_data(sample_word),
        .rd_data(popped),.rd_en(pop),.empty(empty),.full(full),.rd_used(used),.wr_used(),
        .rd_valid(pop_valid),.wr_ready(wr_ready),.rd_ready(rd_ready));
    always @(posedge video_clk or posedge rst) begin
        if(rst) begin pending<=0;holding<=0;held<=0;left<=0;right<=0;underflow<=0;started<=0;ready_sync<=0;missed_samples<=0;minimum_level<=512;end
        else begin
            ready_sync<={ready_sync[1:0],ready};
            if(pop) pending<=1;
            if(pop_valid) begin pending<=0;holding<=1;held<=popped;end
            if(!started && used>=128) started<=1;
            if(sample_tick) begin
                if(started && play && ready_sync[2] && used<minimum_level) minimum_level<=used;
                if(started && holding && ready_sync[2]) begin
                    left<=play?{held[15:0],8'd0}:24'd0;right<=play?{held[31:16],8'd0}:24'd0;holding<=0;
                end else begin
                    left<=0;right<=0;
                    if(started && play && ready_sync[2]) begin
                        underflow<=1;
                        if(missed_samples!=16'hffff) missed_samples<=missed_samples+1'b1;
                    end
                end
            end
        end
    end
    always @(posedge clk) if(state==RECEIVE && valid && received<512) bytes[received[8:0]]<=data;
    // Separate the BRAM clock-to-Q from parser comparisons and offset muxes.
    always @(posedge clk) begin byte_ram_q<=bytes[offset[8:0]];byte_q<=byte_ram_q;end
    // The same offset feeds the BRAM and this registered sector comparison.
    // Inspect neither until byte_wait==2: an increment, chunk jump, loop or
    // completed sector receive must retire its stale byte/tag first.
    reg sector_hit;
    always @(posedge clk or posedge rst)
        if(rst) sector_hit<=0;
        else sector_hit<=(offset>>9)==loaded_sector;
    // RIFF_CHECK consumes the sum captured on the preceding accepted RIFF
    // size byte (index 7). Other cycles are unobserved: computing continuously
    // removes the parser/sector/byte-wait enable chain from this 33-bit bank.
    always @(posedge clk or posedge rst)
        if(rst) riff_limit<=0;
        else riff_limit<={1'b0,assembled}+33'd8;
    // CHUNK consumes only at byte_wait==2, two edges after any offset change;
    // riff_end is fixed in RIFF_CHECK. Keep this 32-bit bound off the offset CE.
    reg chunk_overrun;
    always @(posedge clk or posedge rst)
        if(rst) chunk_overrun<=0;
        else chunk_overrun<=offset>=riff_end;
    task fail(input [7:0] code);begin fault<=code;ready<=0;state<=STOP;end endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;after_byte<=RIFF;req<=0;address<=32'h40000000;received<=0;byte_wait<=0;
            offset<=0;loaded_sector<=32'hffffffff;riff_end<=0;chunk_end<=0;chunk_size<=0;chunk_id<=0;
            next_chunk<=0;padded_chunk<=0;file_limit<=0;
            bounds_invalid<=0;chunk_format_invalid<=0;chunk_data_invalid<=0;format_invalid<=0;
            data_start<=0;data_last<=0;index<=0;word_shift<=0;fmt_seen<=0;stereo<=0;
            format_code<=0;channels<=0;block_align<=0;bits<=0;rate<=0;byte_rate<=0;
            sample_byte<=0;sample_word<=0;push<=0;ready<=0;fault<=0;
        end else begin
            req<=0;push<=0;
            if(state>=RIFF && state<=PCM && byte_wait!=2) byte_wait<=byte_wait+1'b1;
            else if(state>=RIFF && state<=PCM && !sector_hit) begin
                byte_wait<=0;after_byte<=state;state<=FETCH;
            end
            else begin
            byte_wait<=0;
            case(state)
                // Capture FAT metadata at enable; check it locally on the next
                // cycle instead of routing the 32-bit comparison into this FSM.
                IDLE: if(enable) begin file_limit<=file_size;state<=FILE_CHECK;end
                FILE_CHECK: if(file_limit<44) fail(1);else begin after_byte<=RIFF;state<=FETCH;end
                FETCH: if(!busy) begin address<=32'h40000000|(offset>>9);req<=1;received<=0;state<=RECEIVE;end
                RECEIVE: begin
                    if(valid && received<513) received<=received+1'b1;
                    if(ending) begin
                        if(error || received!=512) fail(2);
                        else begin loaded_sector<=offset>>9;state<=after_byte;end
                    end
                end
                // Magic words are checked one byte late from the registered
                // word_shift, keeping the BRAM byte out of the fault/ready path.
                RIFF: begin
                    word_shift<=assembled;offset<=offset+1;index<=index+1'b1;
                    if(index==4 && word_shift!=32'h46464952) fail(3);
                    if(index==7) begin
                        state<=RIFF_CHECK;
                    end
                    if(index==11) state<=RIFF_WAVE;
                end
                RIFF_WAVE: if(word_shift!=32'h45564157) fail(3);else begin state<=CHUNK;index<=0;end
                RIFF_CHECK: begin
                    riff_end<=riff_limit[31:0];
                    bounds_invalid<=riff_limit<44 || riff_limit>file_limit;
                    state<=RIFF_RESUME;
                end
                RIFF_RESUME: if(bounds_invalid) fail(3);else state<=RIFF;
                CHUNK: begin
                    if(chunk_overrun) fail(4);
                    else begin
                        word_shift<=assembled;offset<=offset+1;index<=index+1'b1;
                        if(index==3) chunk_id<=assembled;
                        if(index==7) begin
                            index<=0;chunk_size<=assembled;state<=CHUNK_ADD;
                        end
                    end
                end
                CHUNK_ADD: begin next_chunk<={1'b0,offset}+{1'b0,chunk_size};state<=CHUNK_PAD;end
                CHUNK_PAD: begin
                    padded_chunk<=next_chunk+chunk_size[0];
                    // Precompute the inclusive last byte; do not put an
                    // incrementer before the per-byte loop comparison.
                    data_last<=next_chunk[31:0]-1'b1;state<=CHUNK_CHECK;
                end
                CHUNK_CHECK: begin
                    chunk_end<=padded_chunk[31:0];
                    bounds_invalid<=padded_chunk>riff_end || padded_chunk>file_limit;
                    // Chunk metadata is stable here. Reduce wide size checks
                    // before the dispatch/ready/data_start enable path.
                    chunk_format_invalid<=chunk_size<16;
                    chunk_data_invalid<=!fmt_seen || chunk_size==0 || (chunk_size&(stereo?3:1))!=0;
                    state<=CHUNK_DISPATCH;
                end
                CHUNK_DISPATCH: begin
                    if(bounds_invalid) fail(4);
                    else if(chunk_id==32'h20746d66) begin
                        if(chunk_format_invalid) fail(5);else state<=FORMAT;
                    end else if(chunk_id==32'h61746164) begin
                        if(chunk_data_invalid) fail(5);
                        else begin data_start<=offset;ready<=1;sample_byte<=0;state<=PCM;end
                    end else begin offset<=padded_chunk[31:0];state<=CHUNK;end
                end
                FORMAT: begin
                    offset<=offset+1;index<=index+1'b1;
                    case(index)
                        0:format_code[7:0]<=b;1:format_code[15:8]<=b;
                        2:channels[7:0]<=b;3:channels[15:8]<=b;
                        4:rate[7:0]<=b;5:rate[15:8]<=b;6:rate[23:16]<=b;7:rate[31:24]<=b;
                        8:byte_rate[7:0]<=b;9:byte_rate[15:8]<=b;10:byte_rate[23:16]<=b;11:byte_rate[31:24]<=b;
                        12:block_align[7:0]<=b;13:block_align[15:8]<=b;14:bits[7:0]<=b;
                        15:begin bits[15:8]<=b;state<=FORMAT_CHECK;end
                    endcase
                end
                FORMAT_CHECK: begin
                    format_invalid<=format_code!=1 || (channels!=1 && channels!=2) || rate!=48000 ||
                        bits!=16 || block_align!=(channels==1?2:4) || byte_rate!=(channels==1?96000:192000);
                    state<=FORMAT_FINISH;
                end
                FORMAT_FINISH: if(format_invalid) fail(5);
                    else begin fmt_seen<=1;stereo<=channels==2;offset<=chunk_end;index<=0;state<=CHUNK;end
                PCM: if(!full && !push && wr_ready) begin
                    offset<=offset+1;sample_byte<=sample_byte+1'b1;
                    case(sample_byte)
                        0:sample_word[7:0]<=b;
                        1:begin
                            sample_word[15:8]<=b;
                            if(!stereo) begin sample_word[31:16]<={b,sample_word[7:0]};sample_byte<=0;push<=1;end
                        end
                        2:sample_word[23:16]<=b;
                        3:begin sample_word[31:24]<=b;push<=1;end
                    endcase
                    if(offset==data_last) begin offset<=data_start;sample_byte<=0;end
                end
                STOP: state<=STOP;
                default: state<=IDLE;
            endcase
            end
        end
    end
endmodule
