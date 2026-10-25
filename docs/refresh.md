# 刷新率：从 IOFBBuildModeList 到 CVDisplayLink 的 30 Hz

## 现象

面板已经按真实 timing 扫描，桌面也已经在 Intel 核显上合成，但系统报告的刷新率仍是 30 Hz。`display_probe.c` 一次典型输出如下：

- `CGDisplayMode` 的刷新率为 0
- `CVDisplayLinkGetNominalOutputVideoRefreshPeriod` 返回的周期折算为 30 Hz
- 面板实际 timing 是 2560x1600、59.877 Hz

这三个数字分别来自三条不同的计算路径。30 Hz 是其中两条路径共同作用的结果，修复需要同时补齐模式列表与 timing 描述。

## 链路：CoreDisplay 如何得到刷新率

第一条路径是模式列表。`IOFBBuildModeList` 从 `IOFBConfig` 读取候选模式，同时参考 `IOFBDetailedTimings`。固件帧缓冲没有详细 timing，这个字典为空，模式列表于是保留 `IOFB0Hz` 的缺省值。`getInformationForDisplayMode` 返回的 `refreshRate` 因此是 0。

第二条路径是模式刷新率的计算。CoreDisplay 只在 `kIODetailedTimingValid` 置位时才为模式重算刷新率；条件不成立时，模式沿用旧值，系统界面与显示器信息都显示 0 或回退值。

第三条路径是 `CVDisplayLink` 的名义周期。这个值取自 WindowServer 的实时 VBL 间隔；模式列表里的 refreshRate 服务于模式信息本身，两条路径各有来源。WindowServer 在缺少真实 VBL 时按 30 Hz 的缺省节拍推进，display link 于是报告 30 Hz，与面板的 59.877 Hz 无关。

由此可以得出修复的结构：给模式列表提供真实 refreshRate，给 CoreDisplay 提供一份 `IODetailedTimingInformationV2`，两条信息合起来才能让第三条路径拿到真实的 VBL 节拍。

## 测量：从 BAR0 读出面板 timing

`XeGfxIntelFB` 在 `start()` 里映射 BAR0，并读取显示引擎的 14 个寄存器与帧计数器。寄存器覆盖 pipe 配置、plane 配置、plane 尺寸、水平与垂直 timing、DDI 配置以及 plane surface 地址；帧计数器位于 `0x70040`。采样窗口是 `IOSleep(500)`，采样前后再读一次校验稳定性，避免读到扫描过程中的中间值。

`xe/firmware-timing.h` 负责校验。它检查 pipe 配置的位域（`31:30 == 0xc0000000`）、plane 使能位、像素格式（XRGB8888）、tiling 位、帧计数器增量（10 到 500 之间）与 elapsed 时间（400 ms 到 2 s），再由水平/垂直总像素算出像素时钟。测试面板的测量结果是：

| 项目 | 值 |
| --- | --- |
| 分辨率 | 2560x1600 |
| 像素时钟 | 276,871,248 Hz |
| 帧计数器 | 30 帧 / 501,024,272 ns |
| 刷新率 | 59.877 Hz |

同一份数据也用于校验缓存的 EDID：`xeFirmwareEDIDTiming` 要求 EDID 头与校验和有效、每个 detailed timing 的几何与极性同 live 寄存器一致、名义刷新率与帧计数器测量值相差不超过 5%。三项同时满足时，面板 timing 的来源字符串写成 `cached-panel-EDID matched to live registers/counter`，试验日志里的 `debug.xegfx_panel_timing_source` 就是这个值。

## 发布：两条接口同时补齐

`getInformationForDisplayMode` 覆盖之后，模式列表对面板自身模式返回真实的 `refreshRate`。该值来自 timing 字的第 10 项（单位 mHz），换算成 `IOFixed1616` 后写入 `info->refreshRate`；同时打开 `kDisplayModeValidFlag`、`kDisplayModeSafeFlag`、`kDisplayModeNativeFlag`，让 `IOFBBuildModeList` 把这个模式保留在显示链路可用的集合里。

`getTimingInfoForDisplayMode` 覆盖之后，面板自身模式会返回一份完整的 `IODetailedTimingInformationV2`。填充逻辑在 `xifbFillDetailedTiming` 里：像素时钟、水平与垂直的 active/blank/sync 偏移与脉宽、同步极性、`numLinks = 1`、`pixelEncoding` 用 RGB CTA-861、每通道 8 bit、sRGB colorimetry、SDR dynamic range。这里有两条约束来自 `IOFramebuffer` 自身的实现：

- `minPixelClock` 与 `maxPixelClock` 必须相等。`setVBLTiming()` 在两者不等时会把像素计数清掉，没有像素计数，共享内存里的 VBL delta 就不会被写入（`iofb.cpp:10615`）。
- 只有面板自身的模式（几何等于测量值 2560x1600）才发布 detailed timing。缩放模式按原样交给基类，避免把 2560x1600 的 timing 描述成别的尺寸。

发布完成后，`getTimingInfoForDisplayMode` 返回成功并置 `kIODetailedTimingValid`，CoreDisplay 得到重算刷新率所需的全部输入。

## 当前状态与验证工具

修正已经写进补丁 `0003`，验证工作正在进行。验证分两个层次：

1. 用户态探针。`display_probe.c` 同时打印 `CGDisplayMode` 刷新率与 `CVDisplayLink` 名义周期，一次运行即可看到两条路径是否都变成 59.877 Hz；`modes_list.c` 列出全部模式，用来确认模式列表保留了原生模式并且带上了 HiDPI 标志。
2. 内核态计数器。试验脚本采集 `debug.xegfx_panel_timing_source`、`debug.xegfx_panel_probe_result` 与 `debug.xegfx_accel` 的 present 计数；timing 来源字符串与寄存器快照能确认这次会话读到的 timing 就是面板的 live timing。

在最近的试验快照里，`display-route-final.json` 记录的 `refreshHz` 仍为 0，说明那次采集发生在模式刷新率发布之前，或者 WindowServer 尚未重算模式表。下一步是在最新 kext 上重跑试验，用探针确认 `CGDisplayMode` 与 `CVDisplayLink` 两处的值，再决定是否需要在 WindowServer 启动序列里调整 framebuffer 的注册顺序。

## 下一步

刷新率链路补齐之后，光标仍然由 WindowServer 软件合成。硬件光标通路已经在显示引擎里定位到可行的放置点，见 `cursor.md`。
