"""Generate rtl/scene_text_rom.v and tb/scene_*.hex: the Chinese OSD text of scene_overlay.

All screen text lives here as plain strings. Four ROM kinds are produced, each in
EG_PHY_BRAM32K blocks (16-bit words, word n of INIT_k at bits [16n+15:16n]; a ROM
of more than 2048 words spans two blocks selected by address bit 11):

* template: 45 text rows x 40 cells. Entry = {slot, right_half, 6'b0, code}.
  slot=0: code is a glyph; a full-width (CJK) glyph covers two 8-pixel cells,
  right_half selects its right cell. slot=1: code is a dynamic slot id that
  scene_overlay resolves to a half-width glyph (digits, hex, blanks).
* font: 16x16 glyphs, glyph g row r half h (8 pixels) at word g*32+r*2+h.
  Half-width glyphs use half 0. Codes 0..21 are fixed (see HALF below).
* title: four 24-pixel bold caption titles, 256x24 each, word i*768+r*32+column/8.
* ticker: 20-pixel scrolling subtitles; main 1024x20 at word r*128+column/8,
  overview hint 512x20 at word 2560+r*64+column/8.

Text pixels are 2-bit coverage levels (0 none, 1 quarter, 2 half, 3 full), pixel j
of a word at bits [2j+1:2j]; scene_overlay blends partial levels over the picture.
Font: Noto Sans SC (SIL Open Font License 1.1), anti-aliased and quantised.
Row indices and slot ids are a fixed contract with rtl/scene_overlay.v.

Usage: python maintenance/make_scene_text.py [--font-dir DIR] [--preview out.png]
"""
import argparse
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = Path(os.environ.get("WINDIR", "Windows")) / "Fonts"
MEDIUM, BOLD = "Noto Sans SC Medium (TrueType).otf", "Noto Sans SC Bold (TrueType).otf"
CELLS = 40

# Fixed half-width codes; scene_overlay builds digits as 1+value, hex 1..16.
HALF = [" ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "A", "B", "C", "D", "E", "F", ".", ":", "/", "×", "-"]
# Dynamic slot ids (resolved in scene_overlay.v).
SLOTS = {
    "PG": 0, "TT": 1,
    "L0": 2, "L1": 3, "L2": 4, "L3": 5,
    "I0": 6, "I1": 7, "I2": 8, "I3": 9,
    "W0": 10, "W1": 11, "W2": 12, "W3": 13,
    "H0": 14, "H1": 15, "H2": 16, "H3": 17,
    "X0": 18, "X1": 19, "X2": 20, "X3": 21, "X4": 22,
    "Y0": 23, "Y1": 24, "Y2": 25, "Y3": 26, "Y4": 27,
    "T0": 28, "T1": 29, "T2": 30, "T3": 31,
    "VO": 32,
    "DI": 33, "DB": 34, "DN": 35,
    "F0": 36, "F1": 37, "F2": 38, "F3": 39,
    "S0": 40, "S1": 41, "S2": 42, "S3": 43, "S4": 44, "S5": 45, "S6": 46, "S7": 47,
    "G0": 48, "G1": 49, "G2": 50, "G3": 51,
    "P0": 52, "P1": 53, "P2": 54, "P3": 55, "P4": 56,
    "R0": 57, "R1": 58, "R2": 59,
    "M0": 60, "M1": 61, "M2": 62, "M3": 63,
    "N0": 64, "N1": 65, "N2": 66,
    "EC": 67,
    "Q0": 68, "Q1": 69,
}
ZX = "{X0}{X1}{X2}.{X3}{X4}"
ZY = "{Y0}{Y1}{Y2}.{Y3}{Y4}"
# Template rows in fixed order (index = row number used by scene_overlay.v).
ROWS = [
    # 0-9 status pill: mode, loading, faults A..F
    "自动轮播 {PG}/{TT}", "手动浏览 {PG}/{TT}", "总览选图 {PG}/{TT}", "正在读卡",
    "故障：频谱溢出", "故障：视频输出", "故障：显存欠载", "故障：内存错误", "故障：媒体错误", "故障：读卡失败",
    # 10-13 maintenance card
    "运维信息",
    "首图 {L0}{L1}.{L2}{L3}秒  初始化 {I0}{I1}.{I2}{I3}秒",
    "原图 {W0}{W1}{W2}{W3}×{H1}{H2}{H3}  缩放 " + ZX + "×" + ZY,
    "运行 {T0}{T1}:{T2}{T3}  轮播 {Q0}{Q1}秒  音量 {VO}",
    # 14-18 fault diagnostics card
    "故障诊断  代码 {EC}",
    "初始化 {DI}  解码 {DB}  文件 {DN}  标志 {F0}{F1}{F2}{F3}",
    "扇区 {S0}{S1}{S2}{S3}{S4}{S5}{S6}{S7}  数据 {G0}{G1}{G2}{G3}",
    "像素 {P0}{P1}{P2}{P3}{P4}  读卡 {R0}-{R1}{R2}",
    "音频 缺样 {M0}{M1}{M2}{M3}  余量 {N0}{N1}{N2}",
    # 19 menu title, 20-40 menu items (one row per value)
    "设置  按键2 换项  按键4 改值",
    "亮度    偏暗", "亮度    标准", "亮度    偏亮",
    "对比度  偏低", "对比度  标准", "对比度  偏高",
    "运维信息  隐藏", "运维信息  显示",
    "可视化  关闭", "可视化  频谱", "可视化  波形",
    "轮播间隔  1秒", "轮播间隔  3秒", "轮播间隔  5秒", "轮播间隔  10秒",
    "音源    测试音", "音源    音乐",
    "音量    {VO}",
    "转场    自上", "转场    自下", "转场    居中",
    # 41-44 caption bodies, one per image slot
    "沿步道行走，减少对林下植被的踩踏",
    "苔藓涵养水分，蕨类新叶卷曲着舒展开来",
    "观鸟请保持距离，不投喂、不惊扰",
    "林区严禁野外用火，离开前确认无火种",
]
TITLES = ["林间步道", "苔藓与蕨类", "林中鸟类", "森林防火"]
TICKER = "欢迎来到森林步道 · 请沿步道游览 · 严禁携带火种 · 垃圾请随身带走 · 按键2 看下一张 · "
BROWSE = "按键2 选择下一张 · 按键4 打开 · 长按按键4 返回 · "


def tokens(text: str) -> list[tuple[str, str]]:
    """Split a template string into ("slot", name) and ("char", c) tokens."""
    out, i = [], 0
    while i < len(text):
        if text[i] == "{":
            j = text.index("}", i)
            out.append(("slot", text[i + 1:j]))
            i = j + 1
        else:
            out.append(("char", text[i]))
            i += 1
    return out


def is_half(c: str) -> bool:
    return c in HALF or (ord(c) < 128)


def glyph_codes() -> dict[str, int]:
    codes = {c: n for n, c in enumerate(HALF)}
    extra_half, full = [], []
    for row in ROWS:
        for kind, value in tokens(row):
            if kind != "char" or value in codes:
                continue
            target = extra_half if is_half(value) else full
            if value not in target:
                target.append(value)
    for c in extra_half + full:
        codes[c] = len(codes)
    if len(codes) > 256:
        raise SystemExit(f"{len(codes)} glyphs exceed the 256-glyph font")
    return codes


LEVEL_EDGES = (32, 96, 160)  # coverage 0..255 -> level 0..3


def level(v: int) -> int:
    return sum(v >= e for e in LEVEL_EDGES)


def render_line(text: str, font: ImageFont.FreeTypeFont, height: int, width: int) -> list[list[int]]:
    """Render a proportional text line into a width x height map of 2-bit levels."""
    top, bottom = font.getbbox("国")[1], font.getbbox("国")[3]
    offset = (height - (bottom - top)) // 2 - top
    canvas = Image.new("L", (width, height), 0)
    ImageDraw.Draw(canvas).text((0, offset), text, font=font, fill=255)
    if font.getlength(text) > width:
        raise SystemExit(f"text wider than {width}px: {text}")
    pixels = canvas.load()
    return [[level(pixels[x, y]) for x in range(width)] for y in range(height)]


def render_glyph(c: str, font: ImageFont.FreeTypeFont, half_font: ImageFont.FreeTypeFont) -> list[int]:
    """16 rows x 2 words of 8 levels; half-width glyphs use the left word only."""
    half = is_half(c)
    face = half_font if half else font
    width = 8 if half else 16
    top, bottom = font.getbbox("国")[1], font.getbbox("国")[3]
    offset = (16 - (bottom - top)) // 2 - top
    canvas = Image.new("L", (width, 16), 0)
    if c != " ":
        x = (width - face.getlength(c)) / 2
        ImageDraw.Draw(canvas).text((x, offset), c, font=face, fill=255)
    pixels = canvas.load()
    rows = [[level(pixels[x, y]) for x in range(width)] + [0] * (16 - width) for y in range(16)]
    return pack(rows, 2)


def pack(levels: list[list[int]], stride: int) -> list[int]:
    words = []
    for row in levels:
        for w in range(stride):
            words.append(sum(row[w * 8 + j] << (2 * j) for j in range(8)))
    return words


def blocks(words: list[int]) -> int:
    return 1 if len(words) <= 2048 else 2


def bram(name: str, words: list[int], doc: str) -> str:
    """One BRAM32K for up to 2048 words, else two selected by a registered addr[11]."""
    n_blocks = blocks(words)
    assert len(words) <= 2048 * n_blocks
    words = words + [0] * (2048 * n_blocks - len(words))
    width = 11 if n_blocks == 1 else 12
    body = ""
    for b in range(n_blocks):
        inits = []
        for n in range(128):
            value = "".join(f"{words[b * 2048 + n * 16 + k]:04x}" for k in reversed(range(16)))
            inits.append(f"        .INIT_{n:02X}(256'h{value})")
        body += (
            "    EG_PHY_BRAM32K #(\n"
            "        .MODE(\"SP16K\"),.DATA_WIDTH_A(\"16\"),.DATA_WIDTH_B(\"16\"),.REGMODE_A(\"NOREG\"),\n"
            "        .CSAMUX(\"1\"),.OCEAMUX(\"1\"),.RSTAMUX(\"0\"),.WEAMUX(\"0\"),\n"
            + ",\n".join(inits) + "\n"
            f"    ) u_rom{b}(.doa(data{b}),.dia(16'd0),.addra(addr[10:0]),.bytea(1'b0),.bytewea(1'b0),\n"
            "        .csa(1'b1),.wea(1'b0),.clka(clk),.rsta(1'b0),.ocea(1'b1),\n"
            "        .dob(),.dib(16'd0),.addrb(11'd0),.byteb(1'b0),.byteweb(1'b0),\n"
            "        .csb(1'b0),.web(1'b0),.clkb(1'b0),.rstb(1'b0),.oceb(1'b0));\n")
    if n_blocks == 1:
        select = "    wire [15:0] data0;\n    assign data=data0;\n"
    else:
        select = ("    wire [15:0] data0,data1;\n    reg bank;\n"
                  "    always @(posedge clk) bank<=addr[11];\n"
                  "    assign data=bank?data1:data0;\n")
    return (
        f"// {doc}\n"
        f"module {name}(input wire clk,input wire [{width - 1}:0] addr,output wire [15:0] data);\n"
        + select + body +
        "endmodule\n\n"
    )


def build(font_dir: Path):
    medium16 = ImageFont.truetype(str(font_dir / MEDIUM), 16)
    half16 = ImageFont.truetype(str(font_dir / MEDIUM), 14)
    bold24 = ImageFont.truetype(str(font_dir / BOLD), 24)
    medium20 = ImageFont.truetype(str(font_dir / MEDIUM), 20)
    codes = glyph_codes()
    template = []
    for row in ROWS:
        cells = []
        for kind, value in tokens(row):
            if kind == "slot":
                cells.append(0x8000 | SLOTS[value])
            elif is_half(value):
                cells.append(codes[value])
            else:
                cells += [codes[value], 0x4000 | codes[value]]
        if len(cells) > CELLS:
            raise SystemExit(f"row wider than {CELLS} cells: {row}")
        template += cells + [0] * (CELLS - len(cells))
    font = [0] * (len(codes) * 32)
    for c, g in codes.items():
        font[g * 32:g * 32 + 32] = render_glyph(c, medium16, half16)
    titles = []
    for t in TITLES:
        titles += pack(render_line(t, bold24, 24, 256), 32)
    ticker = pack(render_line(TICKER, medium20, 20, 1024), 128)
    ticker += pack(render_line(BROWSE, medium20, 20, 512), 64)
    return codes, template, font, titles, ticker


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font-dir", type=Path, default=FONT_DIR)
    parser.add_argument("--preview", type=Path, help="write the glyph sheet PNG")
    args = parser.parse_args()
    codes, template, font, titles, ticker = build(args.font_dir)
    assert len(template) <= 2048 and len(titles) <= 4096 and len(ticker) <= 4096 and len(font) <= 8192
    assert len(codes) <= 192, "scene_overlay addresses font_hi with 11 bits (glyphs 128..191)"
    roms = {"template": template, "font_lo": font[:4096], "font_hi": font[4096:], "title": titles, "ticker": ticker}
    text = ("`timescale 1ns/1ps\n"
            "// Chinese OSD text for scene_overlay: template rows, 16x16 font, caption titles and\n"
            "// subtitles. Generated by maintenance/make_scene_text.py from Noto Sans SC (SIL OFL 1.1);\n"
            "// do not edit by hand. Text pixel j of a word is a 2-bit level at data[2j+1:2j].\n\n")
    docs = {"template": f"{len(ROWS)} template rows x {CELLS} cells: {{slot,right_half,6'b0,code}}",
            "font_lo": f"font glyphs 0-127 ({len(codes)} used): word glyph*32+row*2+half",
            "font_hi": "font glyphs 128-255: word (glyph-128)*32+row*2+half",
            "title": "caption titles 256x24 bold: word image*768+row*32+column/8",
            "ticker": "subtitles 20 rows: main word row*128+column/8, overview hint 2560+row*64+column/8"}
    for name, words in roms.items():
        text += bram(f"scene_{name}_rom", words, docs[name])
        (ROOT / "tb" / f"scene_{name}.hex").write_bytes(
            "".join(f"{w:04x}\n" for w in words + [0] * (2048 * blocks(words) - len(words))).encode())
    (ROOT / "rtl" / "scene_text_rom.v").write_bytes(text.encode())
    print(f"{len(ROWS)} rows, {len(codes)} glyphs ({len(codes) - len(HALF)} beyond the fixed half set)")
    if args.preview:
        sheet = Image.new("L", (16 * 16, ((len(codes) + 15) // 16) * 16), 0)
        for g in range(len(codes)):
            for r in range(16):
                for j in range(16):
                    v = font[g * 32 + r * 2 + j // 8] >> (2 * (j % 8)) & 3
                    sheet.putpixel(((g % 16) * 16 + j, (g // 16) * 16 + r), v * 85)
        sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST).save(args.preview)


if __name__ == "__main__":
    main()
