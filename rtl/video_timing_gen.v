// ============================================================================
// video_timing_gen.v — 640x480@60 时序产生
// 2026 选题一 基础四件套 · 件③ HDMI显示
// 器 件：安路 EG4S20BG256B（康芯 HX4S20）
//
// 职责：用行/帧计数器直接产生 hs/vs/de，
//       并在 vs 沿触发帧读请求（read_req/ack，供件②读帧）。
// 结构：行计数 + 帧计数 + de 区间。
// ============================================================================
`timescale 1ns/1ps

module video_timing_gen #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter H_TOTAL  = 800,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33,
    parameter V_TOTAL  = 525
)(
    input  wire        video_clk,
    input  wire        rst,
    output wire        read_req,       // 帧同步读请求（vs 沿触发）
    input  wire        read_req_ack,
    output reg         hs,
    output reg         vs,
    output reg         de
);

    reg [9:0] hcnt;    // 行内计数 0..H_TOTAL-1
    reg [9:0] vcnt;    // 帧内行计数 0..V_TOTAL-1
    reg       vs_d;
    reg       read_req_r;

    // 行/帧计数
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hcnt <= 10'd0;
            vcnt <= 10'd0;
        end else begin
            if (hcnt == H_TOTAL-1) begin
                hcnt <= 10'd0;
                if (vcnt == V_TOTAL-1)
                    vcnt <= 10'd0;
                else
                    vcnt <= vcnt + 1'b1;
            end else
                hcnt <= hcnt + 1'b1;
        end
    end

    // 时序信号（组合）
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs <= 1'b0;
            vs <= 1'b0;
            de <= 1'b0;
        end else begin
            hs <= (hcnt < H_SYNC);
            vs <= (vcnt < V_SYNC);
            de <= (hcnt >= H_SYNC+H_BP) && (hcnt < H_TOTAL-H_FP) &&
                  (vcnt >= V_SYNC+V_BP) && (vcnt < V_TOTAL-V_FP);
        end
    end

    // 帧读请求：vs 上升沿（新帧开始）触发
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d <= 1'b0;
            read_req_r <= 1'b0;
        end else begin
            vs_d <= vs;
            if (vs && !vs_d)
                read_req_r <= 1'b1;
            else if (read_req_ack)
                read_req_r <= 1'b0;
        end
    end
    assign read_req = read_req_r;

endmodule
