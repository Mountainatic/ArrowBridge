# 显示接管路线：固件帧缓冲、head 4 与 display-pipe 事务

## 起点：固件留下的显示状态

这台机器在 macOS 下没有 Intel 显示驱动。启动时，固件（UEFI）已经把内置屏点亮，并把当前帧缓冲留在显卡的 BAR0 显存窗口里；系统随后由 Apple 的 `IONDRVFramebuffer` 按固件描述的模式接管这块内存，桌面由此显示出来。该模式有分辨率、有像素格式，却没有 timing 描述：`CGDisplayModeGetRefreshRate` 返回 0，`IOFB0Hz` 为空，面板真实的扫描参数只存在于显示引擎的寄存器里。整个接管路线就从这条限制出发：保留固件的帧缓冲与模式，把面板的真实 timing 从寄存器里读出来，再让 WindowServer 通过显示通道把新帧写进同一块内存。

## 结构：三个 kext 的分工

路线由三个内核扩展协作完成，它们分别在显示通路的三个层面上补齐信息。

第一个是 `XeGfxIntelFB`。它是 `IONDRVFramebuffer` 的子类，类名采用 Intel 的命名，使 CoreDisplay 把这块 framebuffer 识别为 Intel 厂商的显示设备，从而打开 `IOPresentment` 这条窗口提交通路。该类在 `start()` 里映射 BAR0、读取显示引擎寄存器并测量面板 timing，随后把测量结果发布成 `XeGfxMeasuredPanelTiming` 属性；它的 `getInformationForDisplayMode` 与 `getTimingInfoForDisplayMode` 负责把 timing 交给上层，细节见 `refresh.md`。

第二个是 `XeGfxAccel`。它负责把这块 Intel 面板注册成加速器的显示头。加速器为最多五个 head 编号，Intel 内置面板占第 4 号；`gNvIgpu = 1` 打开这一路，`serviceMatching("XeGfxIntelFramebuffer")` 的 first-publish 通知让注册发生在 framebuffer 就绪之后。注册完成后，WindowServer 的 display-pipe 事务会进入 `NVDisplayPipe::performTransaction`，由加速器把帧写进面板正在扫描的那块物理内存。

第三个是 `NVRMAGDC`。它替代 NVIDIA 的 AGDC 角色，回答显示控制通道里的 K5 link-config 命令（命令号 `0x921`）。`IOPresentment` 只在 AGDC 给出面板 timing 之后才开始 display-pipe 事务，因此 K5 的答案决定事务通路是否打开；答案的来源与 `XeGfxIntelFB` 相同，都是 BAR0 上同一组寄存器和帧计数器，细节见 `refresh.md` 与补丁 `0004`。

## 数据路径：从 WindowServer 到面板

一次桌面上屏的过程可以按顺序读成四步。

1. WindowServer 把一帧合成到 IOSurface 里，然后通过 `IOPresentment` 发出一条 `IOAccelDisplayPipeTransaction2`。
2. `XeGfxAccel` 的 `performTransaction` 收到事务，取到该事务的扫描目标 `q.kva`。这个地址指向面板真实的帧缓冲（aperture 内映射），显示引擎持续从同一块内存扫描，因此这里就是 LIVE SCANOUT 的对象。
3. 加速器等待面板的下一个 vblank，然后把源帧整块复制进 `q.kva`。复制走 `memcpy`，源与目标的 pitch 相等时一次拷完整帧，不相等时逐行拷。
4. 面板从帧缓冲顶部重新扫描时看到的就是新帧，桌面完成一次上屏。

这条路径的关键属性是扫描与写入共用同一块内存：显示引擎始终扫描固件留下的真实帧缓冲，加速器只在 vblank 之后把新内容写进去。由此得到两个直接后果。第一个后果是撕裂被控制住，因为写入发生在扫描回到顶部的时刻。第二个后果是每帧成本由一次内存复制决定，成本与优化方向见 `performance.md`。

## 证据：一次真实试验的计数器

本项目在 `upstream-trial3-20261025-231837` 这次试验里采集到的计数器可以逐项对上这条路线：

- `debug.xegfxaccel_heads_published/registered/piped` 三个值都是 16，即 bit 4 置位，表示 head 4 已经发布、注册并且有显示通道在驱动。
- `debug.xegfxaccel_iop_ok = 2083`，`iop_ok_h4 = 2083`，`iop_ok_h0` 到 `h3` 全为 0，说明本次会话的 present 全部落在 head 4 上。
- `pipe_init = 4`，`pipe_perform / pipe_complete / pipe_validate = 2083`，说明 display-pipe 事务的初始化、执行与校验次数一致。
- `debug.xegfx_agdc = 1`，`agdc_cmds = 73`，`agdc_refused = 52`，`k5_link = 3`，`k5_caps = 3`，`agdc_fbmap` 中记录到唯一一块 framebuffer（id `0x100000623`），说明 AGDC 已经应答 K5 并发布了 framebuffer 映射。
- 用户态 `display-route-final.json` 记录到 1 个显示器（id 1535231424），模式 2560x1600，framebuffer 类名 `XeGfxIntelFramebuffer`，IOAccelTypes 指向 `NMXAccel`，PCI 标识 `8086:7d67`。

## 下一步：刷新率的来源

路线打通之后，面板已经按真实 timing 扫描，但系统侧的显示链路仍然按 30 Hz 报告刷新周期。这个差异不来自显示通道本身，而来自模式列表与 `CVDisplayLink` 的计算路径；`refresh.md` 沿着这条链路逐层说明，并给出当前正在验证的修复方式。
