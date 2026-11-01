// ============================================================================
// video_pixel_align.v — 像素与 timing 对齐（移位链）
// 2026 选题一 基础四件套 · 件③ HDMI显示
// 器 件：安路 EG4S20BG256B（康芯 HX4S20）
//
// 职责：用移位链把 read_en（帧缓存读使能）与 hs/vs/de 对齐到同一拍，
//       使像素数据与行/帧同步信号同步输出。
// 手法：read_en = de_d[N1]（提前若干拍拉高），数据在 de_d[N2] 锁存，
//       输出 de_r = de_d[N3]（与数据同一拍）。参量化延迟。
// ============================================================================
`timescale 1ns/1ps

module video_pixel_align #(
    parameter DATA_WIDTH = 24,
    parameter READ_DE_DEL = 18,     // read_en 对齐延迟
    parameter LATCH_DEL  = 19,      // 数据锁存延迟
    parameter OUT_DEL    = 20       // 输出 timing 延迟
)(
    input  wire                    video_clk,
    input  wire                    rst,
    output wire                    read_en,
    input  wire [DATA_WIDTH-1:0]   read_data,
    input  wire                    read_valid,
    input  wire                    display_enable,
    input  wire                    hs,
    input  wire                    vs,
    input  wire                    de,
    output wire                    hs_r,
    output wire                    vs_r,
    output wire                    de_r,
    output wire [DATA_WIDTH-1:0]   vout_data
);

    // 移位链长度 = OUT_DEL+1
    localparam SHIFT = OUT_DEL + 1;

    reg [SHIFT-1:0] hs_d;
    reg [SHIFT-1:0] vs_d;
    reg [SHIFT-1:0] de_d;
    reg [DATA_WIDTH-1:0] vout_r;

    assign read_en = de_d[READ_DE_DEL] && display_enable;
    assign hs_r    = hs_d[OUT_DEL];
    assign vs_r    = vs_d[OUT_DEL];
    assign de_r    = de_d[OUT_DEL];
    assign vout_data = vout_r;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_d <= {SHIFT{1'b0}};
            vs_d <= {SHIFT{1'b0}};
            de_d <= {SHIFT{1'b0}};
        end else begin
            hs_d <= {hs_d[SHIFT-2:0], hs};
            vs_d <= {vs_d[SHIFT-2:0], vs};
            de_d <= {de_d[SHIFT-2:0], de};
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst)
            vout_r <= {DATA_WIDTH{1'b0}};
        else if (de_d[LATCH_DEL] && read_valid && display_enable)
            vout_r <= read_data;
        else
            vout_r <= {DATA_WIDTH{1'b0}};
    end

endmodule
