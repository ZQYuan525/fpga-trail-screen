// ============================================================================
// seg_disp.v — 数码管状态码显示
// 2026 选题一 基础四件套 · 件④ 控制
// 器 件：安路 EG4S20BG256B（康芯 HX4S20）
//
// 职责：把 4bit 状态码译码为 7 段，并在 6 位数码管上显示（扫描）。
// 结构：7 段译码与位扫描合在一个模块内。
// ============================================================================
`timescale 1ns/1ps

module seg_disp #(
    parameter integer CLK_FREQ_HZ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst_n,       // 低有效
    input  wire [3:0]  state_code,  // 状态码
    output reg  [5:0]  seg_sel,     // 位选（低有效）
    output reg  [7:0]  seg_data     // 段选 [7:0]（含 dp）
);

    // 7 段译码（共阳：0=亮）
    reg [7:0] code2seg;
    always @(*) begin
        case (state_code)
            4'd0: code2seg = 8'b1100_0000;   // 0
            4'd1: code2seg = 8'b1111_1001;   // 1
            4'd2: code2seg = 8'b1010_0100;   // 2
            4'd3: code2seg = 8'b1011_0000;   // 3
            4'd4: code2seg = 8'b1001_1001;   // 4
            4'd5: code2seg = 8'b1001_0010;   // 5
            4'd6: code2seg = 8'b1000_0010;   // 6
            4'd7: code2seg = 8'b1111_1000;   // 7
            4'd8: code2seg = 8'b1000_0000;   // 8
            4'd9: code2seg = 8'b1001_0000;   // 9
            4'd10: code2seg = 8'b1000_1000;  // A
            4'd11: code2seg = 8'b1000_0011;  // B
            4'd12: code2seg = 8'b1100_0110;  // C
            4'd13: code2seg = 8'b1010_0001;  // D
            4'd14: code2seg = 8'b1000_0110;  // E
            default: code2seg = 8'b1000_1110; // F
        endcase
    end

    // 扫描：只在最低位显示状态码，其余灭
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_sel  <= 6'b111_111;
            seg_data <= 8'hFF;
        end else begin
            seg_sel  <= 6'b111_110;    // 选第 0 位
            seg_data <= code2seg;
        end
    end

endmodule
