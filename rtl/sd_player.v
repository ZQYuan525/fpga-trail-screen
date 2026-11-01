`timescale 1ns/1ps
// Producer owns the write buffer until the display adopts it and releases the old one.
module sd_player #(
    parameter integer CLK_FREQ_HZ=100_000_000,AUTO_MS=1000,DEBOUNCE_MS=20,
    parameter integer PROGRESS_TIMEOUT=CLK_FREQ_HZ,
    parameter integer KEY_EVENTS=0, RUNTIME_CONTROL=0, PRELOAD=0, RETRY_INPUT=0,
    parameter integer SKIP_BAD=0, BAD_RETRIES=2, STREAM_CATALOG=0, DIRECT_SELECT=0
)(
    input wire clk,rst,key_next,key_auto,sd_init_done,
    input wire retry_load,
    input wire key_prev,input wire [1:0] period_select,
    output reg [1:0] current_image,target_image,
    output wire auto_enabled,
    output reg display_valid,output wire [3:0] state_code,
    input wire write_finish_t,
    output wire write_req,input wire write_req_ack,
    output wire write_en,output wire [31:0] write_data,
    input wire write_ready,
    output reg [1:0] write_buf_idx,disp_buf_idx,
    input wire bmp_write_req,output wire bmp_write_req_ack,
    output reg scan_start,load_start,load_abort,
    output reg [31:0] load_sector,
    input wire bmp_ready,scan_done,scan_found_valid,
    input wire [31:0] scan_found_sector,
    input wire [2:0] scan_found_total,
    input wire bmp_px_wr_en,input wire [23:0] bmp_px_data,
    output wire bmp_px_ready,
    input wire bmp_load_done,bmp_load_error,bmp_progress,
    output reg write_abort,input wire write_abort_ack,
    output reg publish_req,input wire publish_ack,
    output reg publish_fade,
    output reg error,load_success,
    output wire preload_done,
    input wire catalog_complete,
    output reg catalog_continue,
    output reg [3:0] bad_slots,
    input wire select_request,input wire [1:0] select_index,input wire browse_active,
    output wire [3:0] cached_slots,catalog_slots,output wire control_busy,
    output reg cancel_abort
);
    localparam BOOT=0,SCAN=1,IDLE=2,LOAD=3,PUBLISH=4,RELEASE=5,ABORT=6,ABORT_RELEASE=7,DISPATCH=8;
    localparam integer AUTO_CYCLES=(CLK_FREQ_HZ/1000)*AUTO_MS;
    reg [3:0] state;
    reg [31:0] sectors[0:3];
    reg [2:0] count;
    reg request_pending,pending_prev;
    reg direct_pending;
    reg [1:0] direct_index;
    reg [1:0] period_q;
    reg first_pending,auto_play,source_done,memory_done;
    reg [3:0] cached;
    reg [1:0] load_retries;
    reg background_load,cancel_load;
    reg retry_pending;
    wire [3:0] catalog_mask=count==4?4'b1111:count==3?4'b0111:count==2?4'b0011:count==1?4'b0001:4'b0000;
    wire [3:0] usable=catalog_mask & ~bad_slots;
    wire [3:0] missing=usable & ~cached;
    assign cached_slots=cached & usable;
    assign catalog_slots=catalog_mask;
    assign control_busy=state!=IDLE;
    wire browse=DIRECT_SELECT && browse_active;
    wire direct_now=DIRECT_SELECT && select_request && cached_slots[select_index];
    wire direct_request=direct_now || (DIRECT_SELECT && direct_pending);
    wire [1:0] direct_target=direct_now?select_index:direct_index;
    wire [1:0] preload_image=missing[0]?0:missing[1]?1:missing[2]?2:3;
    assign preload_done=PRELOAD && count!=0 && missing==0 && (!STREAM_CATALOG || catalog_complete);
    reg bmp_ready_q;
    // Registered availability shortens the sector->decoder->player control path.
    // This player is the sole requester, so readiness cannot be stolen.
    always @(posedge clk or posedge rst)
        if(rst) bmp_ready_q<=0;else bmp_ready_q<=bmp_ready;
    reg [31:0] auto_count,progress_count;
    (* async_reg="true" *) reg [2:0] finish_sync,publish_ack_sync;
    reg finish_seen;
    wire finish_event=finish_sync[2]^finish_seen;
    wire next_press,auto_press,next_debounced,auto_debounced;
    wire prev_press=RUNTIME_CONTROL?key_prev:1'b0;
    wire period_changed=RUNTIME_CONTROL && period_select!=period_q;
    wire [31:0] auto_limit=!RUNTIME_CONTROL?AUTO_CYCLES:
        period_select==0?CLK_FREQ_HZ:period_select==1?CLK_FREQ_HZ*3:
        period_select==2?CLK_FREQ_HZ*5:CLK_FREQ_HZ*10;
    assign auto_enabled=auto_play;
    assign next_press=KEY_EVENTS?key_next:next_debounced;
    assign auto_press=KEY_EVENTS?key_auto:auto_debounced;
    wire [1:0] next_image=({1'b0,current_image}+1>=count)?2'd0:current_image+1'b1;
    wire [1:0] previous_image=current_image==0?count[1:0]-2'd1:current_image-2'd1;
    wire manual_request=direct_request || (count>1 && (next_press || prev_press || request_pending));
    wire direction_prev=next_press?1'b0:prev_press?1'b1:pending_prev;
    reg [1:0] skip_next,skip_prev,first_image;
    integer step,candidate;
    always @(*) begin
        skip_next=current_image;skip_prev=current_image;first_image=0;
        for(step=3;step>=0;step=step-1) if(usable[step]) first_image=step;
        for(step=4;step>=1;step=step-1) begin
            candidate=(current_image+step)&3;
            if(candidate<count && usable[candidate]) skip_next=candidate;
            candidate=(current_image+4-step)&3;
            if(candidate<count && usable[candidate]) skip_prev=candidate;
        end
    end
    wire [1:0] selected_image=direct_request?direct_target:SKIP_BAD?(manual_request && direction_prev?skip_prev:skip_next):
        (manual_request && direction_prev?previous_image:next_image);
    assign state_code=error?4'he:state;
    assign write_req=bmp_write_req;
    assign bmp_write_req_ack=write_req_ack;
    assign write_en=bmp_px_wr_en && bmp_px_ready;
    assign write_data={bmp_px_data,8'h00};
    assign bmp_px_ready=write_ready && state==LOAD;
    key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) next_key(
        .clk(clk),.rst(rst),.key_in(key_next),.press_pulse(next_debounced));
    key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) auto_key(
        .clk(clk),.rst(rst),.key_in(key_auto),.press_pulse(auto_debounced));
    always @(posedge clk or posedge rst) begin
        if(rst) begin finish_sync<=0;publish_ack_sync<=0;finish_seen<=0;end
        else begin
            finish_sync<={finish_sync[1:0],write_finish_t};
            publish_ack_sync<={publish_ack_sync[1:0],publish_ack};
            finish_seen<=finish_sync[2];
        end
    end
    wire load_failed=(bmp_load_done && bmp_load_error) ||
        (progress_count>=PROGRESS_TIMEOUT-1 && !bmp_progress && !finish_event);
    // A key press drops an unfinished background preload so cached frames answer at once;
    // the dropped slot stays uncached and is preloaded again later.
    wire cancel_now=PRELOAD && state==LOAD && background_load && manual_request && !source_done && !bmp_load_done;
    // Abort outputs have only two update conditions. Keep unrelated cache and
    // publication muxes out of this same-cycle failure/acknowledgment path.
    always @(posedge clk or posedge rst) begin
        if(rst) begin load_abort<=0;write_abort<=0;end
        else if(state==LOAD && (load_failed || cancel_now)) begin load_abort<=1;write_abort<=1;end
        else if(state==ABORT && write_abort_ack) begin load_abort<=0;write_abort<=0;end
    end
    // The decoder reports a cancelled preload as a load error until its next
    // load_start; this marks that window so status/diagnostics do not log a fault.
    always @(posedge clk or posedge rst) begin
        if(rst) cancel_abort<=0;
        else if(cancel_now) cancel_abort<=1;
        else if(load_start) cancel_abort<=0;
    end
    integer i;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=BOOT;count<=0;current_image<=0;target_image<=0;
            request_pending<=0;pending_prev<=0;period_q<=0;direct_pending<=0;direct_index<=0;
            first_pending<=0;auto_play<=0;source_done<=0;memory_done<=0;
            cached<=0;background_load<=0;cancel_load<=0;retry_pending<=0;bad_slots<=0;load_retries<=0;catalog_continue<=0;
            auto_count<=0;progress_count<=0;display_valid<=0;
            write_buf_idx<=0;disp_buf_idx<=0;scan_start<=0;load_start<=0;
            load_sector<=0;publish_req<=0;publish_fade<=0;error<=0;load_success<=0;
            for(i=0;i<4;i=i+1) sectors[i]<=0;
        end else begin
            scan_start<=0;load_start<=0;load_success<=0;
            period_q<=period_select;
            if(RETRY_INPUT && retry_load && !SKIP_BAD) retry_pending<=1;
            if(STREAM_CATALOG && scan_found_valid) begin count<=scan_found_total;error<=0;end
            // One queued direction, newest wins; simultaneous next/prev means next.
            // Do not queue startup events before a valid image catalog exists.
            if(count>1 && (next_press || prev_press)) begin
                request_pending<=1;pending_prev<=!next_press;direct_pending<=0;
            end
            if(direct_now) begin direct_pending<=1;direct_index<=select_index;request_pending<=0;end
            if(scan_found_valid && scan_found_total>=1 && scan_found_total<=4)
                sectors[scan_found_total-1'b1]<=scan_found_sector;
            if(auto_press && count>1) begin auto_play<=~auto_play;auto_count<=0;end
            case(state)
                BOOT: if(sd_init_done && bmp_ready_q) begin scan_start<=1;state<=SCAN;end
                SCAN: if(scan_done) begin
                    count<=scan_found_total;first_pending<=scan_found_total!=0;
                    error<=scan_found_total==0;state<=IDLE;
                end
                IDLE: begin
                    if(bmp_ready_q && retry_pending && error) begin
                        retry_pending<=0;
                        if(count==0) state<=BOOT;
                        else begin
                            source_done<=0;memory_done<=0;progress_count<=0;error<=0;
                            load_start<=1;state<=LOAD;
                        end
                    end else if((PRELOAD || bmp_ready_q) && count!=0 && (!SKIP_BAD || usable!=0) && (first_pending || manual_request ||
                        (count>1 && auto_play && !browse && !auto_press && !period_changed && auto_count>=auto_limit-1))) begin
                        target_image<=first_pending?(SKIP_BAD?first_image:0):selected_image;
                        publish_fade<=!first_pending && manual_request && display_valid;
                        load_sector<=sectors[first_pending?(SKIP_BAD?first_image:0):selected_image];
                        if(!first_pending) begin request_pending<=0;direct_pending<=0;end
                        write_buf_idx<=PRELOAD?(first_pending?(SKIP_BAD?first_image:0):selected_image):(display_valid?(disp_buf_idx^2'd1):0);
                        background_load<=0;
                        first_pending<=0;auto_count<=0;progress_count<=0;
                        source_done<=0;memory_done<=0;error<=0;retry_pending<=0;load_retries<=0;
                        // Latch selection before consulting the cache, keeping
                        // direction/wrap selection out of the dispatch path.
                        if(PRELOAD) state<=DISPATCH;
                        else begin load_start<=1;state<=LOAD;end
                    end else if(PRELOAD && bmp_ready_q && display_valid && !error && missing!=0) begin
                        target_image<=preload_image;write_buf_idx<=preload_image;load_sector<=sectors[preload_image];
                        background_load<=1;source_done<=0;memory_done<=0;progress_count<=0;load_retries<=0;
                        publish_fade<=0;
                        load_start<=1;state<=LOAD;
                    end else if(auto_play && !browse && !auto_press && !period_changed && auto_count<auto_limit) auto_count<=auto_count+1;
                    if(SKIP_BAD && !display_valid && usable!=0 && !first_pending) first_pending<=1;
                    if(SKIP_BAD && count!=0 && usable==0) begin
                        first_pending<=0;error<=1;catalog_continue<=1;
                    end
                end
                DISPATCH: begin
                    // Cached frames need only the display handshake. WAV may
                    // own SD indefinitely and keep BMP readiness low.
                    if(SKIP_BAD && display_valid && target_image==current_image) state<=IDLE;
                    else if(cached[target_image]) begin publish_req<=1;state<=PUBLISH;end
                    else if(bmp_ready_q) begin load_start<=1;state<=LOAD;end
                end
                LOAD: begin
                    if(bmp_load_done && !bmp_load_error) source_done<=1;
                    if(finish_event) memory_done<=1;
                    if(bmp_progress || finish_event) progress_count<=0;
                    else progress_count<=progress_count+1;
                    if(load_failed) begin
                        error<=1;state<=ABORT;
                    end else if(cancel_now) begin
                        cancel_load<=1;state<=ABORT;
                    end else if((source_done || bmp_load_done) && (memory_done || finish_event)) begin
                        if(PRELOAD) cached[target_image]<=1;
                        if(PRELOAD && background_load) begin load_success<=1;state<=IDLE;end
                        else begin publish_req<=1;state<=PUBLISH;end
                    end
                end
                PUBLISH: if(publish_ack_sync[2]) begin
                    publish_req<=0;disp_buf_idx<=write_buf_idx;current_image<=target_image;
                    display_valid<=1;load_success<=1;catalog_continue<=1;state<=RELEASE;
                end
                RELEASE: if(!publish_ack_sync[2]) begin auto_count<=0;state<=IDLE;end
                ABORT: if(write_abort_ack) begin state<=ABORT_RELEASE;end
                ABORT_RELEASE: if(!write_abort_ack && bmp_ready_q) begin
                    auto_count<=0;
                    if(cancel_load) begin cancel_load<=0;state<=IDLE;end
                    else if(SKIP_BAD && load_retries<BAD_RETRIES) begin
                        load_retries<=load_retries+1'b1;source_done<=0;memory_done<=0;
                        progress_count<=0;error<=0;load_start<=1;state<=LOAD;
                    end else begin
                        if(SKIP_BAD) begin
                            bad_slots[target_image]<=1;error<=0;load_retries<=0;
                            if(!display_valid) catalog_continue<=1;
                        end
                        state<=IDLE;
                    end
                end
                default: state<=BOOT;
            endcase
            if(period_changed || browse) auto_count<=0;
        end
    end
endmodule
