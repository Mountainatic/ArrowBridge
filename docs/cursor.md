# 硬件光标：haveHWCursor 门与 LPG 光标通路

## 现状

里程碑桌面上的光标由 WindowServer 软件合成：系统把光标绘制进合成后的帧里，再随整帧一起送到显示通道。这条路径能工作，代价是每帧多一次光标绘制，而且光标移动会连带整帧更新。显示引擎本身具备独立的光标通道，硬件光标可行；当前工作是把这条通道接上。

## 结构：IONDRVFramebuffer 的光标判定

`IONDRVFramebuffer` 为子类提供 `haveHWCursor` 这个判定入口。基类在没有 NDRV 与加速器的情况下按软件光标处理：`haveHWCursor` 返回 `false`，WindowServer 由此走软件合成路径，把光标画进帧缓冲。`XeGfxIntelFB` 目前继承这一行为，没有覆盖任何光标方法，所以桌面稳定运行在软件光标形态。

打开硬件光标需要三个条件同时成立：

1. `haveHWCursor` 返回 `true`，WindowServer 才会把光标位置与图像交给 framebuffer，由显示引擎独立合成；软件路径则由 WindowServer 把光标画进帧。
2. 显示引擎能读到一张光标图像。LPG 显示引擎的光标通道用 `CUR_CTL`、`CUR_POS`、`CUR_BASE`、`CUR_SURFLIVE` 这一组寄存器：`CUR_CTL` 控制格式与开关，`CUR_POS` 设置左上角位置，`CUR_BASE` 指向光标图像的显卡地址，`CUR_SURFLIVE` 读回当前正在扫描的地址。
3. 光标图像的地址落在显示引擎可访问的地址空间里。固件帧缓冲位于 aperture 内，显示引擎按物理地址直接扫描这块内存；光标图像只有放在同一段 aperture 里，并且与 firmware 写入 `PLANE_SURF` 的地址处在同一个映射区间，才能用 `CUR_BASE` 指过去。

第三个条件解释了为什么补丁 `0003` 先在 `intelfb.cpp` 里做一次放置诊断，再考虑寄存器编程。

## 诊断：aperture 尾部是否可用

`XeGfxIntelFB::start()` 在 `IONDRVFramebuffer::start()` 之后调用 `getApertureRange(kIOFBSystemAperture)`，取得启动 aperture 的物理地址与长度，同时从 BAR0 读回 firmware 写入的 plane surface 地址。两者用于判定地址映射关系：

- 当 aperture 的物理地址等于 `PLANE_SURF & 0x7fffffff` 时，显示引擎看到的地址与 CPU 看到的物理地址一致，尾部空间可以放光标图像，日志写 `identity mapped, tail usable`。
- 两者不一致时，显示引擎的地址空间与 CPU 的物理地址之间存在偏移，直接写 `CUR_BASE` 会把光标指到错误地址，日志写 `NOT identity mapped, do not use CURBASE yet`。

尾部空间的长度取 `aperture 长度 - 0xFA0000`。这里的 `0xFA0000` 等于 16,384,000 字节，正好是一帧 2560x1600 XRGB 的大小；换算之后，尾部空间从帧缓冲结束处开始计数。诊断假设光标图像占 256 KB，这个尺寸可以放下一张 256x256 的 ARGB 光标，也可以在 64x64 与 128x128 之间做双缓冲。日志同时给出 surface 地址、aperture 物理地址与尾部字节数，便于在真机上核对。

## 计划：接入 LPG 光标通道

实现分四步，前一步的结果决定后一步是否继续。

1. **确认放置点**。用 `cursor placement` 日志确认 `identity mapped, tail usable` 出现在真实启动之上，并且尾部空间足够 256 KB。若日志给出 `NOT identity mapped`，需要先解决 aperture 地址映射，再回到本步骤。
2. **预约图像区**。在 aperture 尾部预留 256 KB，作为光标图像的稳定落点；该区域位于帧缓冲之后，与扫描区不重叠，因此光标更新不会破坏扫描内容。
3. **覆盖光标方法**。在 `XeGfxIntelFramebuffer` 里覆盖 `haveHWCursor` 并返回 `true`，同时覆盖光标状态更新方法：把图像写入预约区，按 WindowServer 给出的位置写 `CUR_POS`，按图像地址写 `CUR_BASE`，再通过 `CUR_CTL` 打开光标通道；需要读回时使用 `CUR_SURFLIVE`。
4. **验证与回退**。移动光标并观察显示：光标位置跟随、图像无残影、display-pipe 事务周期不退化。任何一步失败都回退到软件光标，`haveHWCursor` 继续返回 `false`，桌面保持当前可用状态。

## 观测手段

光标通路的验证依赖三类观测：

- `XeGfxIntelFB` 的日志：`cursor placement` 一行给出放置点与尾空间，寄存器读取值可以判断光标通道是否真的在扫描。
- 加速器计数器：硬件光标打开后，WindowServer 不再把光标画进帧，present 的帧内容与耗时会有可测量的变化；`debug.xegfxaccel_iop_*` 的 copy/txn 统计可以对比开关前后的差别。
- 用户态探针：`display_probe.c` 与 `modes_list.c` 确认显示模式与刷新率没有因为光标改动而变化。

## 下一步

光标通路的成本与显示通道同属一类问题：软件光标让每帧多一次绘制，硬件光标则把这次绘制从帧路径里移走。帧路径当前的主要成本仍然是整帧复制，见 `performance.md`。
