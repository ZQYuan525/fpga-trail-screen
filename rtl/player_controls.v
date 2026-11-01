`timescale 1ns/1ps
// Release-triggered keys prevent a menu chord from leaking a normal action.
module player_controls #(
    parameter integer CLK_HZ=100_000_000, DEBOUNCE_MS=20, HOLD_MS=800, LONG_MS=1000, PERSISTENCE=0, EXTENDED_MENU=0, ADVANCED=0
)(
    input wire clk,rst,key1,key2,
    input wire restore,input wire [15:0] restored,
    output reg next_event,auto_event,prev_event,
    output wire [15:0] settings,
    output reg [2:0] volume,output reg [1:0] transition_kind,
    input wire [3:0] available,input wire [1:0] current_image,input wire player_busy,
    output reg view_mode,confirm_pending,select_event,
    output reg [1:0] focus_index,select_index,visualization
);
    localparam integer DB=(CLK_HZ/1000)*DEBOUNCE_MS;
    localparam integer HOLD=(CLK_HZ/1000)*HOLD_MS;
    localparam integer LONG=(CLK_HZ/1000)*LONG_MS;
    localparam integer MAX_COUNT=HOLD>LONG?(HOLD>DB?HOLD:DB):(LONG>DB?LONG:DB);
    localparam integer COUNT_W=$clog2(MAX_COUNT+1);
    (* async_reg="true" *) reg [1:0] sync1,sync2;
    reg [1:0] stable,previous;
    reg [COUNT_W-1:0] count1,count2,held,long_count;
    reg chord,menu,long_marked;
    reg [COUNT_W-1:0] browse_hold;
    reg browse_marked;
    reg [2:0] selection;
    reg [1:0] brightness,contrast,period_select;
    reg osd,spectrum,media_audio;
    assign settings={menu,selection,brightness,contrast,osd,spectrum,period_select,media_audio,3'b0};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            sync1<=3;sync2<=3;stable<=3;previous<=3;
            count1<=0;count2<=0;held<=0;chord<=0;menu<=0;long_count<=0;long_marked<=0;
            selection<=0;brightness<=1;contrast<=1;osd<=1;spectrum<=1;
            period_select<=0;media_audio<=1;volume<=4;transition_kind<=0;
            next_event<=0;auto_event<=0;prev_event<=0;
            browse_hold<=0;browse_marked<=0;view_mode<=0;confirm_pending<=0;select_event<=0;
            focus_index<=0;select_index<=0;visualization<=1;
        end else begin
            sync1<={key2,key1};sync2<=sync1;previous<=stable;
            next_event<=0;auto_event<=0;prev_event<=0;select_event<=0;
            if(ADVANCED && confirm_pending && !player_busy && current_image==select_index) begin
                confirm_pending<=0;view_mode<=0;
            end
            if(sync2[0]==stable[0]) count1<=0;
            else if(count1>=DB-1) begin stable[0]<=sync2[0];count1<=0;end
            else count1<=count1+1;
            if(sync2[1]==stable[1]) count2<=0;
            else if(count2>=DB-1) begin stable[1]<=sync2[1];count2<=0;end
            else count2<=count2+1;
            if(stable==0) begin
                chord<=1;
                if(held<HOLD) held<=held+1;
                if(held==HOLD-1 && !(ADVANCED && confirm_pending)) begin menu<=~menu;if(ADVANCED) view_mode<=0;end
            end else held<=0;
            if(stable==3 && previous==3) begin chord<=0;long_marked<=0;browse_marked<=0;end
            if(ADVANCED && !menu && !chord && !confirm_pending && stable==2 && sync2==2) begin
                if(browse_hold<LONG) browse_hold<=browse_hold+1'b1;
                if(browse_hold==LONG-1 && !browse_marked) begin
                    view_mode<=~view_mode;focus_index<=current_image;browse_marked<=1;
                end
            end else browse_hold<=0;
            // A chord takes precedence. Check the synchronized other key as
            // well, so its debounce interval cannot leak a long-key action.
            if(!menu && !chord && stable==1 && sync2==1) begin
                if(long_count<LONG) long_count<=long_count+1;
                if(long_count==LONG-1 && !long_marked) begin
                    if(ADVANCED && view_mode) begin if(!confirm_pending) view_mode<=0;end
                    else prev_event<=1;
                    long_marked<=1;
                end
            end else long_count<=0;
            if(!chord && stable!=0) begin
                if(stable[0] && !previous[0]) begin
                    if(menu) selection<=selection==(EXTENDED_MENU?7:5)?0:selection+1'b1;
                    else if(ADVANCED) begin
                        if(!browse_marked && !confirm_pending) begin
                            if(view_mode) focus_index<=focus_index+1'b1;else next_event<=1;
                        end
                    end else next_event<=1;
                end
                if(stable[1] && !previous[1]) begin
                    if(!menu) begin
                        if(!long_marked) begin
                            if(ADVANCED && view_mode) begin
                                if(!confirm_pending && available[focus_index]) begin
                                    if(!player_busy && focus_index==current_image) view_mode<=0;
                                    else begin select_index<=focus_index;select_event<=1;confirm_pending<=1;end
                                end
                            end else auto_event<=1;
                        end
                    end
                    else case(selection)
                        0:brightness<=brightness==2?0:brightness+1'b1;
                        1:contrast<=contrast==2?0:contrast+1'b1;
                        2:osd<=~osd;
                        3:begin
                            if(ADVANCED) begin
                                visualization<=visualization==2?0:visualization+1'b1;
                                spectrum<=visualization!=2;
                            end else spectrum<=~spectrum;
                        end
                        4:period_select<=period_select+1'b1;
                        5:media_audio<=~media_audio;
                        6:if(EXTENDED_MENU) volume<=volume==4?0:volume+1'b1;
                        7:if(EXTENDED_MENU) transition_kind<=transition_kind==2?0:transition_kind+1'b1;
                    endcase
                end
            end
            if(PERSISTENCE && restore) begin
                brightness<=restored[11:10];contrast<=restored[9:8];osd<=restored[7];spectrum<=restored[6];
                period_select<=restored[5:4];media_audio<=restored[3];
                if(ADVANCED) visualization<=restored[6]?1:0;
            end
        end
    end
endmodule
