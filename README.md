# 独立播放器工程（player_next）

Anlogic EG4S20BG256（TD 6.2.1）上的 TF 卡图片与音乐播放器：从 FAT32 读取 BMP，缩放到 640×480 后经 HDMI 输出，同时播放 WAV；带中文说明叠加、OSD 菜单、滚动字幕、四图总览、转场、随音乐生长的草地频谱与波形显示。应用场景：无网络、光伏供电、无人值守的森林公园步道点位科普屏。

## 当前版本

- 位流 SHA-256 `8a63ab00197712427c6ac49f17adc05cec4164a371eb96ad3fd4ccc132eb52c4`，固化在板载配置 Flash，上电自启动。
- 配置：SPI 模式 3、`SD_SPI_DIV=5`（10 MHz），不带参数保存（`ENABLE_PERSISTENCE=0`），`example.al` 带 `hfn_opt_effort=low`。
- 时序与资源：SWNS +0.139 / HWNS +0.004 ns，LUT 84.09%，REG 57.60%，slice 8683（TD 在 slice 超过 90% 时跳过 hold fix），BRAM9K 61/64，BRAM32K 12/16，DSP 24/29。
- 验证：ModelSim 回归（本包默认 68 项）；从配置 Flash 冷启动 10/10，首图冷上电 1.64 s / KEY1 复位 1.21 s（演示卡），连续运行 ≥2 h。

## 操作

| 输入 | 作用 |
|---|---|
| KEY1 | 整机复位 |
| KEY2 / KEY3 | 下一张 / 上一张 |
| KEY4 短按 | 自动轮播开关；总览中确认选图 |
| KEY2 长按 1 s | 四图总览 |
| KEY2+KEY4 保持 800 ms | 进入/退出参数菜单（亮度、对比度、音量、可视化、转场等） |
| SW1 上拨 | 高对比度显示 |
| SW2 上拨 | 隐藏 OSD 与字幕（演示时两只拨码都拨在下面） |
| 丝印 LED1–LED4 | 自动轮播 / 图片加载中 / HDMI 音频非零 / 故障 |
| 蜂鸣器 | 开机短鸣；故障持续 1 s 后长鸣一次 |
| 数码管 | 运行信息轮播；60 s 无操作熄灭，按键唤醒 |

## 目录

```text
工程根目录/
├─ README.md          本说明
├─ example.al         TD 6.2.1 工程文件
├─ run_tests.py       ModelSim 回归（默认 68 项）
├─ build_td.py        命令行构建 TD 并检查时序
├─ prepare_media.py   生成测试图片、音乐与 FAT32 镜像
├─ rtl/               Verilog 源码
├─ ip/                厂商 IP、PLL；ip/fft/ 为 MIT 许可的 r22sdf FFT（见其 LICENSE）
├─ constraints/       引脚与时序约束
├─ tb/                仿真测试平台、SD 卡与 SDRAM 模型、ROM 数据
└─ maintenance/       TF 卡备份与写卡脚本，Logo / 中文字库 / 草地图 ROM 生成脚本
```

仿真、构建和媒体生成的中间文件都放在工程根目录下的 `work/`（运行时自动创建），不混进源码目录。

## 使用

```powershell
# 先设工具目录：MODELSIM_BIN = ModelSim 的 win32aloem 目录，TD_ROOT = TD 6.2.1 安装目录
# ModelSim 回归（在工程根目录下运行）
python run_tests.py
```

- 用 `python build_td.py --bitstream` 构建：源码先复制到 `work/builds/` 下的独立目录再运行 TD。
- 现场从 U39 上电自启动，不从主机下载位流。

## 媒体约定

- FAT32，512 字节扇区；取根目录前四个有效 BMP 短目录项（ID 0–3）和第一个 WAV。
- BMP：未压缩 RGB24，1×1～1280×960，缩放到 640×480；首图用 640×480 时加载最快。
- WAV：PCM16，48 kHz，单声道或双声道。卡上没有 WAV 时播放随图片变化的提示音（音视频联动）。

## 已知局限

- 拔卡后插回不会自动恢复（重试 3 次后停在故障状态），按 KEY1 恢复。
- 开机先把四幅图全部缓存到 SDRAM，之后切图不读卡；音乐在预载完成后淡入，上电后约 5–10 s（视卡的读速）。
- 不带参数保存；未使用 CMD18 多块读。
- slice 已接近 TD 跳过 hold fix 的门槛，新增逻辑须先看构建日志里的 slice 数。
