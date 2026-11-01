// ============================================================================
// key_debounce.v — 按键消抖
// 2026 选题一 基础四件套 · 件④ 控制
// 器 件：安路 EG4S20BG256B（康芯 HX4S20）
//
// 职责：低有效按键消抖，输出单拍 press_pulse（按下沿）。
// 结构：同步 + 稳定窗口计数。
// ============================================================================
`timescale 1ns/1ps

module key_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,            // 高有效
    input  wire key_in,         // 低有效按下
    output reg  press_pulse     // 按下单拍
);

    localparam integer STABLE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_W = STABLE_CYCLES > 1 ? $clog2(STABLE_CYCLES) : 1;

    reg s0, s1;                 // 两级同步
    reg stable;
    reg [CNT_W-1:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s0 <= 1'b1;
            s1 <= 1'b1;
            stable <= 1'b1;
            cnt <= {CNT_W{1'b0}};
            press_pulse <= 1'b0;
        end else begin
            s0 <= key_in;
            s1 <= s0;
            press_pulse <= 1'b0;

            if (s1 == stable) begin
                cnt <= {CNT_W{1'b0}};
            end else begin
                if (cnt >= STABLE_CYCLES - 1) begin
                    // 稳定后：检测按下（stable 高 -> s1 低）
                    if (stable && !s1)
                        press_pulse <= 1'b1;
                    stable <= s1;
                    cnt <= {CNT_W{1'b0}};
                end else
                    cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
