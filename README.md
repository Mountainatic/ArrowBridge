# ArrowWhatever

**ArrowWhatever** 是面向 Intel Arrow Lake-HX Xe-LPG 核显的 macOS 图形项目，当前主要针对 Intel Core Ultra 9 275HX（`8086:7D67`）与 macOS Tahoe 26.7.1。项目已经打通 XeGfx、Mesa ANV、XeMTL、WindowServer 与内屏显示链路：加速桌面可以稳定运行，显示提交已经从整帧 CPU copy 推进到 GGTT 零拷贝 flip，并通过 K9 deferred flip 把 GPU 完成与扫描切换从 WindowServer 的同步等待中解耦。

最近的工作开始把原来依赖手动 bring-up 的显示链前移到驱动启动阶段：core 现在能够从 VBT 建立内建 eDP 信息，经 AUX 自动读取 EDID/DPCD，macOS 已能正确识别内建面板；在此基础上又加入了 K1 级别的 i915 eDP 只读接管，为后续同模式 modeset、240 Hz 与 DSC 做准备。

仓库保存经过验证的补丁、安装/试验工具与技术记录，上游源码从对应项目获取。同机 OpenCore 配置见 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi)。

## 当前状态

| 项目 | 状态 | 当前结果 |
| --- | --- | --- |
| Xe-LPG Metal / WindowServer | ✅ 已验证 | Intel 核显可作为 Metal 设备参与桌面合成 |
| GGTT 零拷贝显示 | ✅ 已验证 | 三槽轮转，display-pipe 直接 flip 到 compositor surface backing |
| K9 deferred flip | ✅ 已验证 | 2560x1600@60Hz 下恢复到约 60fps，无需 WindowServer 逐帧同步等待 |
| 原生显示启动链 | ✅ 已进入仓库 | VBT、DisplayNub、只读 KMS KAPI、scanout、boot arm、AGDC/accel/adapter 启动链已整理为 0011–0019 |
| EDID / DPCD 自动读取 | ✅ 实机验证 | BOE `0x0D55`，DPCD 1.4，HBR3 x4，DSC 1.2，支持 AUX 背光 |
| macOS 内建屏身份 | ✅ 实机验证 | `AppleDisplay` 出现 `IODisplayEDID`，识别为内建面板并加载色彩描述 |
| K1 i915 eDP takeover | 🧪 已实现，待实机运行 | i915 建立 connector/CRTC 并读取固件管线，不 sanitize、不 modeset |
| K2 同模式 modeset | ⏳ 下一阶段 | 先让 i915 在不改变当前 raster 的前提下真正提交一次模式 |
| K3 240 Hz + DSC / HiDPI | ⏳ 后续 | 在 K2 稳定后再切 HBR3 + DSC 与高刷新模式 |

这里的“已验证”只指当前 275HX 实机上的结果；K1 已通过编译、链接、KPI 与 shadow 检查，但最新提交明确还没有做真实 GPU/display 写入试验。

## 启动方式与工作机制

早期稳定链路仍保留“系统先进入 macOS，再分阶段拉起 GPU、图形 API 与显示通路”的方式，便于回归和故障隔离。0011 之后开始把 VBT、显示 nub、scanout、AGDC、framebuffer 与 boot arm 逐步前移到驱动启动阶段；0020/0021 已经完成 EDID/DPCD 自动读取，0022 则开始让 i915 以只读方式建立 eDP/KMS 状态。

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

11. **原生显示链把手动 bring-up 前移到驱动内部**

   `0011–0019` 把此前只存在于本机 native-display 工作区的显示接管链整理进仓库：core 采集 VBT、发布 `XeGfxDisplayNub` 与只读 KMS KAPI，adapter 提供独立的 XeGfxDisplay framebuffer，accel/AGDC 通过内核内请求完成 arm，bootguard 负责冷启动闸门、健康检查与失败回退。

   这一阶段还修了两个会直接影响 WindowServer 的问题：framebuffer 的 C++ 类名必须包含 Intel，才能让 CoreDisplay 正确识别 GPU vendor 并启用 IOPresentment；AGDC 在 framebuffer 尚未出现时也不能提前停止轮询，否则显示映射永远不会建立。

12. **AUX 自动读取 EDID / DPCD，macOS 不再看到 Unknown Display**

   `0020-core-aux-edid-dpcd.patch` 根据 VBT 中的内建 eDP child 找到 AUX 通道，在 i915 尚未接管显示寄存器时直接完成 DPCD 与 I2C-over-AUX EDID 读取；`0021-adapter-edid-ddc.patch` 再按照 IOGraphicsFamily 的调用语义把 EDID 交给 macOS。

   当前实机读到 384 B EDID，面板为 BOE `0x0D55`；链路能力为 DPCD 1.4、HBR3 x4、8b/10b、DSC 1.2，并报告 AUX 背光支持。macOS 侧已经出现 `AppleDisplay` / `IODisplayEDID`，显示身份从 Unknown Display 收敛为内建面板。

13. **K1：i915 只读接手 eDP 状态**

   `0022-core-k1-staged-edp-takeover.patch` 开始真正启用 i915 的显示信息，但第一阶段仍然不修改当前固件点亮的 raster。K1 只建立内建 eDP connector/CRTC、读取 fixed modes 与当前硬件状态，并持有活动管线需要的电源引用；同时跳过 sanitize、initial commit、hotplug、fbdev 与 OpRegion 注册，避免第一步就改变正在扫描的管线。

   K1 当前已经通过 424/424 编译、链接、KPI 与 shadow 检查并装机，**尚未进行实机运行验证**。后续路线是 K2 同模式提交，再到 K3 的 HBR3 + DSC + 240 Hz。

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


### 7. WindowServer 因 framebuffer 身份与 AGDC 时序走错路径

原生显示接管初期，WindowServer 会在 `CA::OGL::Context::push_surface` 断言后循环退出。进一步检查 CoreDisplay / QuartzCore 后发现，framebuffer 的 C++ 类名不含 Intel 时，CoreDisplay 会把 GPU vendor 判错并清掉 IOPresentment；同时 AGDC 在 framebuffer 尚未出现时如果停止轮询，也会让映射永远无法建立。

`0017-agdc-pending-retry.patch` 让 AGDC 在 pending 状态继续重试，`0018-adapter-intel-class-name.patch` 则用 `XeGfxIntelKMSFramebuffer` 暴露正确的 Intel framebuffer 身份。随后实机恢复 Metal 整屏合成，`pipe_perform` 与 `iop_xe_flips` 持续增长，WindowServer 不再出现原来的断言循环。

### 8. Unknown Display：此前根本没有人读取 EDID

显示链稳定以后，macOS 仍把内屏识别为 Unknown Display。排查后确认问题不是 EDID 内容错误，而是此前整条链上没有任何组件真正从面板读取过 EDID。

`0020` 在 core 侧经 AUX 读取 EDID 与 DPCD，`0021` 修正 adapter 的 DDC 响应，包括 block 编号、built-in connection type、Apple Sense 行为以及 `IODisplay::readFramebufferEDID()` 对 `hddc` capability probe 的调用方式。修正后系统能够读取 384 B EDID，并正确建立内建 AppleDisplay。

### 9. 从“沿用固件模式”开始过渡到 i915 KMS

前面的零拷贝与 K9 都仍然依赖固件已经点亮的显示 raster，只改变扫描 surface；这足以稳定显示，但无法真正切换缩放分辨率、240 Hz 或 DSC。

`0022` 因此把显示接管拆成 K1 → K2 → K3 三步。K1 先只读建立 i915 的 eDP/KMS 世界，不写显示寄存器；K2 再尝试提交与当前固件完全相同的模式；只有 K2 稳定后，K3 才进入 HBR3 + DSC + 240 Hz。这样把“能不能接管”与“能不能换模式”拆开，避免一次改动同时引入太多变量。

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
| `0011-core-native-display-m0-m4a.patch` | 0001/0008 之后 | VBT、DisplayNub、只读 KMS KAPI、scanout 与 boot arm |
| `0012-accel-m3d-m4a-present-bootarm.patch` | 0009 之后 | adapter/accel present contract 与开机自动配置 |
| `0013-agdc-m3d-in-kernel-arm.patch` | 0004 之后 | AGDC 改为内核内 arm，并移除固定时序头文件 |
| `0014-intelfb-l0-ready.patch` | 0010 之后 | framebuffer start 完成后再发布 L0 ready |
| `0015-adapter-xegfxdisplay-kms.patch` | 新增 | XeGfxDisplay KMS adapter |
| `0016-tools-native-display-bringup.patch` | 新增 | M0–M4a 启动、安装、守护与验证工具 |
| `0017-agdc-pending-retry.patch` | 0013 之后 | framebuffer 晚到时继续重试 AGDC |
| `0018-adapter-intel-class-name.patch` | 0015 之后 | 暴露 Intel framebuffer 类名，修正 CoreDisplay vendor 识别 |
| `0019-guard-tools-class-name-and-keep-armed.patch` | 0016 之后 | health/preflight 适配新类名并支持持久 arm |
| `0020-core-aux-edid-dpcd.patch` | 0011 之后 | 经 AUX 自动读取 EDID/DPCD |
| `0021-adapter-edid-ddc.patch` | 0018 之后 | 按 IOGraphicsFamily 语义提供 EDID/DDC |
| `0022-core-k1-staged-edp-takeover.patch` | 0020 之后 | K1 i915 eDP 只读接管 |

补丁的应用顺序与基点提交见 [patches/README.md](patches/README.md)。

## 构建与试验

1. 克隆 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe)。
2. core 检出 `5a19a73f`，应用 `0001–0004`、`0008–0010`，再按顺序叠加 `0011–0022`。其中 `0013` 需要 `patch -E` 删除已经清空的旧时序头文件。
3. plugin 检出 `497d521e`，依次应用 `0005 → 0006 → 0007`；plugin 与 0.0.44 core 的补丁基点不要混用。
4. 构建 XeGfx core、XeGfxAccel、XeGfxIntelFB、XeGfxAGDC、XeGfxDisplay 与 XeMTL；具体依赖与命令见 [docs/building.md](docs/building.md)。
5. 根目录 `scripts/` 保留早期手动 bring-up 与压测流程；0016 另外提供当前原生显示链的 `tools/` 安装、preflight、bootguard、health 与 rollback 工具。
6. 路径规则已经统一：仓库内工具从脚本自身位置解析；仓库外源码树与构建产物通过 `XEGFX_*` 环境变量显式指定；`/Library`、`/System`、`/usr` 等系统路径保持固定绝对路径。
7. K9 基线仍可通过 `scripts/run_upstream_trial5.sh` / `resume-bringup.sh` 回归；原生显示链则按 0016 的 M0–M4a 工具逐阶段验证。
8. `0020/0021` 的验收重点是 IORegistry 中的 `IODisplayEDID`、built-in identity 与 DPCD/EDID dump；`0022` K1 目前只应验证 readout，不应期待模式切换。
9. 使用 `scripts/soak_userptr_test.sh` 做 userptr 长压测，使用 `scripts/tools/display_probe.c` 检查刷新节拍。

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

ArrowWhatever 目前主要在这一台 275HX 实机上边试边改，开发过程中会大量使用 LLM 辅助查资料、写代码和排错。仓库里的结论以实际编译、日志和硬件验证为准，不保证换到其他机器上可以直接复现。
