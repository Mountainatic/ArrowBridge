# ArrowWhatever

**ArrowWhatever** 是面向 Intel Arrow Lake-HX Xe-LPG 核显的 macOS 图形项目。关注于 Intel Core Ultra 9 275HX 的 Tohoe 适配，核显设备号为 `8086:7D67`，系统为 macOS Tahoe 26.7.1。目前整合 XeGfx 内核驱动、ANV Vulkan、XeMTL Metal、WindowServer 桌面合成与内屏显示链路，推进到 GGTT 槽零拷贝 flip，K9 延迟 flip 又把 GPU 完成与扫描面切换从 WindowServer 同步等待中解耦，在 2560x1600@60Hz 的当前面板上恢复到约 60fps 的加速桌面。

仓库保存经过验证的补丁、安装脚本、试验脚本与技术记录，上游源码从对应项目获取。同机 OpenCore 配置见 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi)。

## 启动方式与工作机制

当前驱动以依赖分阶段拉起。系统先完整进入 macOS，再逐层启动 GPU、图形 API 与显示通路，对于常规 EDID 识别与 framebuffer 启动的路径正在补全

1. **OpenCore 先把系统带入可操作状态**

   使用 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi) 启动 macOS Tahoe。固件留下的 framebuffer 继续维持内屏扫描，为后续核显接管提供稳定起点。

2. **XeGfx 启动 Arrow Lake Xe-LPG**

   使用 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 中的 `gpu/xegfx`，其 XNU 适配层来自 [watchthelight-labs/XeGfx](https://github.com/watchthelight-labs/XeGfx)。这一层把 FreeBSD drm-kmod 中的 i915 带到 XNU，完成 PCI、内存、IRQ、GuC、render、copy 与 compute engine 的初始化。

   当前 core 基线为 [NvGfx xe 提交 5a19a73f](https://github.com/watchthelight-labs/NvGfx/commit/5a19a73f36249efb99c44c3f9cb34603ef0c0eb8)，对应 XeGfx 0.0.44。

3. **ANV 把 i915 暴露为 Vulkan 设备**

   使用 [Mesa](https://gitlab.freedesktop.org/mesa/mesa) 的 ANV Vulkan 驱动，并配合 NvGfx xe 分支中的 Darwin libdrm 适配。ANV 通过 i915 ioctl 管理 GEM 对象、context、userptr 与提交队列，最终得到可执行 compute 与 render workload 的 Vulkan 设备。

4. **XeMTL 把 Metal 接到 ANV**

   使用 [NvGfx xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 中 0.0.35 时期的 `plugin` 模块作为基线，并改编为 XeMTL。Metal shader 经 metal2vulkan 翻译后进入 Vulkan 与 ANV，WindowServer 因而能够把 Intel Xe-LPG 作为 Metal 设备完成桌面合成。

   插件基线为 [NvGfx xe 提交 497d521e](https://github.com/watchthelight-labs/NvGfx/commit/497d521e925bd760c8cde5bbc17d9bf96d2ee2b4)。

5. **XeGfxAccel 把核显接入 macOS 加速器通道**

   使用 NvGfx xe 分支中的 XeGfxAccel 与 NMXAccel 结构，把 Intel 内屏注册为 head 4，并向 WindowServer 提供 IOKit 图形通道。WindowServer 的 Metal 合成结果由此进入 `IOAccelDisplayPipeTransaction2`。

6. **XeGfxIntelFB 发布面板时序与 HiDPI 模式**

   使用 NvGfx xe 分支中的 `XeGfxIntelFB` 模块读取 BAR0 显示寄存器和帧计数器，取得真实面板时序。当前实测模式为 2560x1600，像素时钟 276871248 Hz，扫描频率 59.877 Hz。

   ArrowWhatever 在这一层发布 `IOFBDetailedTimings`，并补充 mode information 与 detailed timing。补丁同时加入 1280x800 HiDPI 桌面模式，底层 raster 继续保持 2560x1600，WindowServer 使用 2x backing 完成缩放。

7. **NVRMAGDC 打开 IOPresentment 显示事务**

   使用 NvGfx xe 分支中的 `NVRMAGDC` 模块回答 K5 link-config 命令 `0x921`，把 XeGfxIntelFB 测得的 timing 交给显示控制链。AGDC 完成握手后，IOPresentment 开始向 head 4 发送 display-pipe transaction。

8. **XeGfx core 为合成帧建立 GGTT 零拷贝槽**

   ArrowWhatever 在 XeGfx core 中加入 `xgFlipInit`、`xgFlipMap` 与 `xgFlipUnmap`。core 使用 i915 的全局 GGTT 预留三个槽，每个槽覆盖一帧 2560x1600 XRGB surface。槽使用 `I915_COLOR_UNEVICTABLE` 保持地址稳定，首次实测落在 `0x80000000` 开始的 GGTT 区域。

   WindowServer 交来的 IOSurface 位于系统内存。XeGfxAccel 通过 `IOMemoryDescriptor` 取得物理页，再经 XeGfxResident 的 platform function 桥把这些物理页写入对应 GGTT 槽的 PTE。

9. **display-pipe 直接 flip 到 surface backing**

   XeGfxAccel 完成新帧的 GGTT 映射后，不再由 CPU 搬运整帧。三个槽按帧轮转，当前帧与前两帧持续保留映射，后续 flip 确认旧槽退出扫描后再回收。CPU copy 保留为故障回退路径，`debug.xegfxaccel_iop_xe_flip=0` 可以在运行时切回拷贝提交。

10. **K9 延迟 flip 把 GPU 完成与扫描切换移到内核侧排序**

   直接 no-wait 可以让 WindowServer 更快返回，但如果 GPU 尚未完成写入就立即改 `PLANE_SURF_1_A`，会出现半路呈现、撕裂和 UI 异常。ArrowWhatever 因此在 core 侧加入 `xgFlipQuery` 空闲探测，并在 XeGfxAccel 中加入 defer worker：新帧先映射到 GGTT 槽，WindowServer 提交立即返回，worker 等待 i915 engine 空闲后再 arm plane，最终仍由 vblank 锁存新 surface。

   这条 K9 路径由 `debug.xegfxaccel_iop_xe_defer=1` 控制，`defer_armed`、`defer_signals` 与 `wait_max_us` 提供运行时观测；`debug.xegfxaccel_iop_xe_defer=0` 可以退回同步 flip。

## 推进过程中解决的问题

下面按照前面的链路顺序记录关键问题与修正。

### 1. userptr 页释放竞态

GPU workload 稳定运行后，i915 在 GEM userptr 对象回收阶段触发过：

```text
xegfx: vm: freeing wired page 0x... ref 0x1
```

调用链进入 `i915_gem_userptr_put_pages`、`linux_release_pages` 与 `xg_bsd_vm_page_free`。进一步检查发现，page hold 与最后一次 unwire 分处两个临界区。最后一个引用准备释放时，新的 pin 仍有机会重新进入同一页，最终形成带 wiring 的释放状态。

ArrowWhatever 在 `0001-xg_vm-userptr-race.patch` 中把 userptr page hold 与末次 unwire 统一到同一套状态机，并加入私有 `XG_VPO_USERHOLD` 标记。最后一次 unwire 负责摘除 run 和释放页，page lifetime 因而保持单向收敛。


### 2. 只读 host pointer 导致 device lost

WindowServer 会交给 XeMTL 一部分只读 host mapping。早期插件直接把这些地址作为可写 external host memory 导入 ANV，随后 i915 以 `FOLL_WRITE` 语义 pin userptr。只读 VMA 在这一阶段返回失败，execbuffer 最终得到 EFAULT，ANV 再把状态上送为 `VK_ERROR_DEVICE_LOST`。

ArrowWhatever 在 `0006-plugin-host-import.patch` 中加入 `nvmtl_range_writable` 判定。可写范围继续使用 host import，其余范围进入 copy path。这样让 userptr 权限与实际 VMA 权限保持一致。

修正后，连续桌面试验跨越多次启动保持稳定，execbuffer EFAULT 与 device lost 主链已经消失。

### 3. display-pipe 事务需要完整的显示握手

Metal 合成打通以后，下一步是让 WindowServer 的帧稳定进入 Intel 内屏。这里需要同时满足 framebuffer 发布、head 注册、AGDC link-config 与 IOPresentment transaction 四个条件。

ArrowWhatever 在 `0002-accel-vblank-and-head4.patch` 中注册 head 4，并把 present 放到真实面板 vblank 之后。随后在 `0003-intelfb-panel-timing.patch` 中发布实时测得的面板 timing，再由 `0004-agdc-k5-panel-timing.patch` 应答 K5 link-config。


### 4. 系统刷新节拍与真实面板扫描频率分离

面板寄存器和帧计数器给出的真实扫描频率为 59.877 Hz，而 CoreDisplay 早期读取到的 mode refresh 为 0，CVDisplayLink 则按 30 Hz 推进。

ArrowWhatever 先从 BAR0 读取 live timing，再由 XeGfxIntelFB 补充 `getInformationForDisplayMode` 与 `getTimingInfoForDisplayMode`。随后 `0010-intelfb-detailed-timings.patch` 把同一份 timing 发布到 `IOFBDetailedTimings`，并增加 1280x800 HiDPI 模式。原生模式与 HiDPI 模式共享 2560x1600 raster，面板扫描参数保持一致。

这一步已经进入最新 framebuffer 补丁，后续验证继续观察 CGDisplayMode、CVDisplayLink 与模式列表是否全部收敛到真实面板节拍。

### 5. 整帧 CPU copy 推进到 GGTT 零拷贝 flip

早期 display-pipe 会把每个 2560x1600 XRGB surface 整帧复制到 firmware framebuffer。单帧数据量为 16384000 字节，常规 copy 耗时约 1.3 到 2.3 ms，峰值曾达到 19 到 60 ms。峰值跨越 vblank 时会带来撕裂，同时每帧 16 MB 写流量持续占用 CPU 与内存带宽。

ArrowWhatever 在 `0008-core-ggtt-flip-slots.patch` 中让 XeGfx core 预留 GGTT 槽，并通过 `xgFlipInit`、`xgFlipMap` 与 `xgFlipUnmap` 管理槽的 PTE。随后 `0009-accel-zero-copy-flip.patch` 让 XeGfxAccel 取得 IOSurface 的物理页，映射到空闲槽，再把槽的 GGTT 偏移写入 `PLANE_SURF_1_A`。

帧生命周期由三槽轮转维护。新帧先完成映射，再提交 plane surface；当前帧与前两帧继续持有 backing，后续 flip 再回收最旧槽。映射失败、物理页获取失败或桥调用失败时，事务进入已经验证过的 CPU copy 回退路径。

首次零拷贝验收运行 200 秒，记录：

- `pipe_perform = 2837`
- `iop_ok = 0`
- `flip_miss = 0`
- `flip_fail = 0`
- kernel panic 计数为 0
- DEVICE_LOST 计数为 0

随后桌面继续稳定运行 30 分钟以上，撕裂现象也随整帧 copy 退出主路径而消失。

### 6. K9 延迟 flip：去掉 WindowServer 的逐帧 GPU 完成等待

零拷贝 flip 打通以后，WindowServer 仍曾在 `commitAndWaitUntilSubmitted` 一类同步路径里每帧等待 GPU 完成，实测等待约 7.5–12.8 ms/帧；简单 no-wait 虽把窗口基准从 19.1fps 提高到 28.4fps，但会破坏 GPU 写入与扫描切换的顺序。

K9 把这个顺序约束移到内核侧：core 的 `xg_i915_idle()` 通过 `xgFlipQuery` 暴露 engine 空闲状态，XeGfxAccel 的 defer worker 在帧完成后再 arm `PLANE_SURF_1_A`。在 2560x1600@60Hz 的当前面板上，延迟 flip 已把加速桌面恢复到约 60fps，同时保持窗口拖动、滚动与光标正常，无撕裂。

完整机制、sysctl 与手动 bring-up 流程见 [docs/k9-deferred-flip.md](docs/k9-deferred-flip.md)。


## 硬件与系统

| 项目 | 取值 |
| --- | --- |
| 机型 | MECHREVO Yaoshi 16 Ultra |
| CPU | Intel Core Ultra 9 275HX Arrow Lake-HX |
| 核显 | Intel Xe-LPG: 8086:7D67 |
| 独显 | NVIDIA GeForce RTX 5080 Laptop |
| 内存 | 64 GB |
| 系统 | macOS Tahoe 26.7.1 · 25G241 |

## 补丁结构

| 补丁 | 基线 | 作用 |
| --- | --- | --- |
| `0001-xg_vm-userptr-race.patch` | XeGfx 0.0.44 | 修正 userptr page lifetime |
| `0002-accel-vblank-and-head4.patch` | XeGfx 0.0.44 | 注册 head 4 并按 vblank present |
| `0003-intelfb-panel-timing.patch` | XeGfx 0.0.44 | 测量并发布真实面板 timing |
| `0004-agdc-k5-panel-timing.patch` | XeGfx 0.0.44 | 回答 AGDC K5 link-config |
| `0005-plugin-xemtl-port.patch` | XeGfx 0.0.35 plugin | 把插件改编为 XeMTL |
| `0006-plugin-host-import.patch` | XeMTL | 修正只读 host import |
| `0007-plugin-first-loss-journal.patch` | XeMTL | 首损日志、no-wait 提交分支与逐调用 census instrumentation |
| `0008-core-ggtt-flip-slots.patch` | XeGfx 0.0.44 | GGTT 零拷贝槽、flip bridge 与 `xgFlipQuery` engine-idle 探测 |
| `0009-accel-zero-copy-flip.patch` | 0002 之后 | GGTT 零拷贝 display flip 与 K9 defer worker |
| `0010-intelfb-detailed-timings.patch` | 0003 之后 | 发布 IOFBDetailedTimings 与 1280x800 HiDPI 模式 |

补丁的应用顺序与基点提交见 [patches/README.md](patches/README.md)。

## 构建与试验

1. 克隆 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe)。
2. core 检出 `5a19a73f`，先应用 `0001` 到 `0004`。
3. 在同一 core 树继续应用 `0008`、`0009` 与 `0010`，补入 GGTT flip 与 detailed timings。
4. plugin 检出 `497d521e`，依次应用 `0005` 到 `0007`。
5. 使用 `build/nvgfx/build_xegfx.sh` 构建 XeGfx core。
6. 使用对应构建入口生成 XeGfxAccel、XeGfxIntelFB、NVRMAGDC 与 XeMTL。
7. 使用 `scripts/install_core_044.py`、`install_upstream_accel.py` 与 `install_xeintelfb.py` 安装并重建 AuxKC。
8. 早期链路可以继续用 `scripts/run_upstream_trial4.sh` 做分阶段验证；当前 K9 手动 bring-up 使用 `scripts/run_upstream_trial5.sh`，`scripts/resume-bringup.sh` 则把 core、head 4、display-pipe、K9 sysctl 与单次 WindowServer 重启串成完整恢复流程。
9. 使用 `debug.xegfxaccel_iop_xe_flip=1` 进入 GGTT 零拷贝路径；K9 另外打开 `debug.xegfxaccel_iop_xe_defer=1`，并观察 `iop_xe_flips`、`iop_xe_flip_miss`、`iop_xe_flip_fail`、`defer_armed` 与 `defer_signals`。
10. 使用 `scripts/soak_userptr_test.sh` 做 userptr 长压测，使用 `scripts/tools/display_probe.c` 检查刷新节拍。

完整构建说明见 [docs/building.md](docs/building.md)。

## 文档

- [显示接管路线](docs/route.md)
- [零拷贝 GGTT flip](docs/zero-copy-flip.md)
- [device lost 修正](docs/device-lost.md)
- [userptr panic 修正](docs/userptr-panic.md)
- [刷新率链路](docs/refresh.md)
- [硬件光标计划](docs/cursor.md)
- [帧路径性能](docs/performance.md)
- [K9 延迟 flip](docs/k9-deferred-flip.md)
- [XeMTL 插件说明](docs/plugin.md)


## 许可与致谢

`patches/` 是对 NvGfx 与 XeGfx 上游源码的修改，沿用 PolyForm Noncommercial License 1.0.0。全文见 [LICENSE](LICENSE)。

`scripts/`、`docs/`、`README.md` 与 `NOTICE.md` 以 MIT 许可发布。全文见 [LICENSE-MIT](LICENSE-MIT)。

驱动主体来自 NullMoth Systems 的 macOS Metal 驱动体系。ArrowWhatever 使用 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 与 [watchthelight-labs/XeGfx](https://github.com/watchthelight-labs/XeGfx)，并使用 Mesa ANV、metal2vulkan、FreeBSD drm-kmod 与 Intel GuC firmware。完整来源与署名见 [NOTICE.md](NOTICE.md)。

ArrowWhatever 的适用范围以当前实机验证结果为准。项目主要由 LLM 驱动构建，自用代码不一定适用于所有情况。
