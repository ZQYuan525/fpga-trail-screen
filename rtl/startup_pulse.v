// ============================================================================
// startup_pulse.v — 上电单脉冲
// 2026 选题一 基础四件套 · 件④ 控制
// 器 件：安路 EG4S20BG256B（康芯 HX4S20）
//
// 职责：复位释放后延时 N 拍，输出一个单拍脉冲（用于 EDID 读取触发等）。
// 结构：延时计数 + 单拍输出。
// ============================================================================
`timescale 1ns/1ps

module startup_pulse #(
    parameter integer CNT_MAX = 100_000
)(
    input  wire clk,
    input  wire rst,        // 高有效
    output reg  o_pulse
);

    localparam integer CNT_W = CNT_MAX > 0 ? $clog2(CNT_MAX+1) : 1;
    reg [CNT_W-1:0] cnt;
    reg        fired;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt    <= {CNT_W{1'b0}};
            fired  <= 1'b0;
            o_pulse<= 1'b0;
        end else begin
            o_pulse <= 1'b0;
            if (!fired) begin
                if (cnt >= CNT_MAX) begin
                    o_pulse <= 1'b1;
                    fired   <= 1'b1;
                end else
                    cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
