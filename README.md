# ArrowWhatever

**ArrowWhatever** 是面向 Intel Arrow Lake-HX Xe-LPG 核显的 macOS 图形项目，当前主要针对 Intel Core Ultra 9 275HX 与 macOS Tahoe 26.7.1，使用的核显设备号为 `8086:7D67`。项目已经打通 [XeGfx](https://github.com/watchthelight-labs/XeGfx) 内核驱动、[Mesa ANV](https://gitlab.freedesktop.org/mesa/mesa) Vulkan、XeMTL Metal、WindowServer 桌面合成与内屏显示链路，并完成 GGTT 零拷贝 flip 与 K9 延迟 flip。

目前工作的重点已经转向显示链前端：让驱动从启动阶段自动建立内屏，现在已经可以从 VBT 获取内建 eDP 信息，经 AUX 自动读取 EDID 与 DPCD，并让 macOS 正确识别内建面板；接下来继续分阶段推进 i915 对 eDP 管线的适配，先只读恢复固件状态，到 modeset ，最终进入 HBR3 + DSC 和 1920x1200@240Hz HiDPI。

仓库保存经过验证的补丁、安装脚本、试验脚本与技术记录，上游源码从对应项目获取。同机 OpenCore 配置见 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi)。

## 启动方式与工作机制

启动阶段由固件维持内屏扫描，XeGfx 通过 boot-arm 在内核线程中推进 GPU 与显示初始化。VBT、EDID、DPCD、framebuffer、加速器与 AGDC 按 IOKit 依赖逐层建立，WindowServer 随后接入 XeMTL、ANV 与显示提交链。

1. **固件维持内屏扫描**

   使用 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi) 启动 macOS Tahoe。固件留下当前 raster 与 scanout，内屏在 XeGfx 初始化期间保持显示。

2. **XeGfx 在启动阶段完成 GPU 初始化**

   使用 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 中的 `gpu/xegfx`，XNU 适配层来自 [watchthelight-labs/XeGfx](https://github.com/watchthelight-labs/XeGfx)。boot-arm 触发后，XeGfx 在内核线程中依次推进 stage 1–7，完成 PCI、内存、IRQ、GuC 与 render/copy/compute engine 初始化。

   当前 core 基线为 [NvGfx xe 提交 5a19a73f](https://github.com/watchthelight-labs/NvGfx/commit/5a19a73f36249efb99c44c3f9cb34603ef0c0eb8)，对应 XeGfx 0.0.44。

3. **i915 解析 VBT 并建立内建显示信息**

   stage 4 读取 ACPI OpRegion 与 VBT，取得内建 eDP child、面板 timing 与 connector 信息。XeGfx 发布 `XeGfxDisplayNub`，并提供 VBT、child 记录、KMS KAPI 与 scanout 接口。

4. **AUX 读取 EDID 与 DPCD**

   core 根据 VBT 中的内建 eDP child 定位 AUX 通道，读取 DPCD，并通过 I2C-over-AUX 获取 EDID，同时取得链路速率、lane 数、DSC 与背光能力等面板信息。

   EDID 与 DPCD 以 `xegfx-edid` 和 `xegfx-dpcd` 随 display nub 发布，XeGfxDisplay 按 IOGraphicsFamily 的 DDC 接口提供给 macOS。

5. **K1 读取 i915 eDP 管线状态**

   `xegfx-disp-kms=1` 启用 K1 后，i915 建立内建 eDP encoder/connector，读取 fixed modes、CRTC、CDCLK 与当前活动管线状态，并持有对应的显示电源引用。当前阶段保持固件 raster，供后续 modeset 继续接管。

6. **XeGfxDisplay 建立 framebuffer 与 scanout**

   `XeGfxDisplay.kext` 匹配 `XeGfxDisplayNub`，读取 KMS KAPI、面板模式与 EDID，建立 `XeGfxIntelKMSFramebuffer`。framebuffer 通过 KAPI 分配 scanout，并把 scanout 信息交给 XeGfxAccel。CoreDisplay 通过 Intel framebuffer 类名识别核显显示设备，并启用 IOPresentment。

7. **XeGfxAccel 与 AGDC 建立显示事务**

   XeGfxAccel 等待 framebuffer 完成启动与 scanout 准备，将内屏注册到 display machine，导入 scanout，并发布 present 接口与 AGDC 请求。XeGfxAGDC 随后完成 framebuffer 映射与 K5 link-config，建立 framebuffer、head 与 display pipe 的对应关系。

8. **WindowServer 进入 XeMTL、ANV 与显示提交链**

   XeGfxAccel 向系统暴露 XeMTL Metal 插件。XeMTL 基于 [NvGfx xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 0.0.35 时期的 plugin 改编，Metal shader 经 metal2vulkan 进入 [Mesa](https://gitlab.freedesktop.org/mesa/mesa) ANV，再通过 i915 ioctl 提交到 XeGfx。

   WindowServer 的合成结果进入 IOPresentment/display-pipe 通路。合成 surface 映射到 XeGfx core 预留的 GGTT 槽，K9 deferred flip 在 GPU 完成后 arm 新 surface，并由 vblank 锁存到扫描面。

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


### 7. framebuffer 身份错误导致 WindowServer 走错显示路径

原生显示接管刚开始时，WindowServer 会在 `CA::OGL::Context::push_surface` 断言后反复退出。检查 CoreDisplay 与 QuartzCore 后发现，`XeGfxFramebuffer` 这个类名不包含 Intel，CoreDisplay 因而没有把它识别为 Intel framebuffer，IOPresentment 被静默关闭，桌面退回旧式 surface 路径。

`0018-adapter-intel-class-name.patch` 增加 `XeGfxIntelKMSFramebuffer` 子类，只改变对外类名，不改变 framebuffer 行为。与此同时，`0017-agdc-pending-retry.patch` 让 AGDC 在 framebuffer 晚到时继续重试。修正后实机恢复 Metal 整屏合成，WindowServer 不再出现原来的断言循环。

### 8. Unknown Display 的根因是链路里没有真正读取 EDID

早期 framebuffer 只发布固件留下的 timing，系统始终把内屏识别为 Unknown Display。进一步检查后确认，并不是 EDID 内容解析错误，而是此前没有任何组件真正经 AUX 向面板读取过 EDID。

`0020` 在 core 侧补上 AUX 事务与 I2C-over-AUX EDID 读取，`0021` 修正 adapter 的 DDC block 编号、built-in connection type、Apple Sense 与 `hddc` capability probe。修正后系统可以读取完整 EDID，并建立正确的内建显示身份。

### 9. 240 Hz 需要从“沿用固件 raster”推进到真正的 i915 modeset

前面的零拷贝 flip 与 K9 都仍然沿用固件已经点亮的显示模式，只改变扫描 surface。这足以稳定显示，但不能真正切换分辨率、刷新率或 DSC。

因此显示接管被拆成 K1、K2、K3 三步：K1 只读建立 i915 的 eDP/KMS 状态；K2 在不改变当前模式的前提下完成第一次同模式提交；K3 再进入 HBR3、DSC 与 240 Hz。这样可以把“接管显示管线”和“切换高刷新模式”分开验证。

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

项目使用两套上游源码基点。XeGfx core 与显示相关 kext 基于 [NvGfx `xe` 提交 `5a19a73f`](https://github.com/watchthelight-labs/NvGfx/commit/5a19a73f36249efb99c44c3f9cb34603ef0c0eb8)，对应 XeGfx 0.0.44；XeMTL 基于 [NvGfx `xe` 提交 `497d521e`](https://github.com/watchthelight-labs/NvGfx/commit/497d521e925bd760c8cde5bbc17d9bf96d2ee2b4) 的 `plugin/`，对应 XeGfx 0.0.35。

| 组件 | 源码起点 | 补丁链 | 当前作用 |
| --- | --- | --- | --- |
| XeGfx core / xkpi | XeGfx 0.0.44 · `5a19a73f` | `0001 → 0008 → 0011 → 0020 → 0022` | userptr、GGTT、boot-arm、VBT/KMS、AUX EDID/DPCD、K1 eDP readout |
| XeGfxAccel | XeGfx 0.0.44 · `5a19a73f` | `0002 → 0009 → 0012` | display-pipe、零拷贝 present、adapter/accel contract、启动配置 |
| XeGfxIntelFB | XeGfx 0.0.44 · `5a19a73f` | `0003 → 0010 → 0014` | panel timing、detailed timing、L0 ready |
| XeGfxAGDC | XeGfx 0.0.44 · `5a19a73f` | `0004 → 0013 → 0017` | AGDC/K5、内核 arm、framebuffer pending retry |
| XeGfxDisplay | ArrowWhatever `0015` | `0015 → 0018 → 0021` | KMS framebuffer adapter、Intel framebuffer identity、EDID/DDC |
| native-display tools | ArrowWhatever `0016` | `0016 → 0019` | build/install、preflight、bootguard、health、rollback |
| XeMTL | XeGfx 0.0.35 plugin · `497d521e` | `0005 → 0006 → 0007` | Metal 插件、host import、first-loss journal |

每条补丁链按表中顺序应用。完整文件范围、应用命令与依赖关系见 [patches/README.md](patches/README.md)。

## 构建与试验

1. 准备 NvGfx `xe` 的两个源码基点：`5a19a73f` 用于 XeGfx core 与显示 kext，`497d521e` 用于 XeMTL plugin。
2. 按“补丁结构”中的组件链应用补丁。core、accel、IntelFB、AGDC 与 XeGfxDisplay 在 0.0.44 源码树中构建；XeMTL 在 0.0.35 的 `plugin/` 树中构建。
3. 使用 `build/nvgfx/build_xegfx.sh` 构建 XeGfx core，使用对应构建入口生成 XeGfxAccel、XeGfxIntelFB 与 XeGfxAGDC，使用 `tools/build-xegfxdisplay.sh` 构建 XeGfxDisplay。
4. 使用 `build/nvgfx/build_xlate.sh` 与 `build/nvgfx/build_plugin.sh` 生成 translator 与 `XeMTLDriver.bundle`。
5. 0016 工具集负责 kext 产物检查、安装、AuxKC 重建、boot-arm 配置、preflight、health 与 rollback。仓库外源码树和构建产物通过 `XEGFX_*` 环境变量传入。
6. 重启后的验证顺序对应启动链：XeGfx stage 1–7、`XeGfxDisplayNub`、EDID/DPCD、K1 eDP 状态、XeGfxDisplay framebuffer/scanout、XeGfxAccel、AGDC/K5、WindowServer Metal 与 display-pipe。
7. 图形稳定性使用 `scripts/soak_userptr_test.sh`、display probe、bootguard/health 输出和统一日志进行检查。K1 当前验证范围为 eDP 状态读取与管线恢复，后续 modeset 继续沿同一链路推进。

完整构建、安装与验证说明见 [docs/building.md](docs/building.md)。

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

ArrowWhatever 的适用范围以当前实机验证结果为准。开发过程中会大量使用 LLM 辅助查资料、写代码和排错，仓库里的结论仍以实际编译、日志和硬件验证为准。
