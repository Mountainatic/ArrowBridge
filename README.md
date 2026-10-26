# ArrowBridge

**ArrowBridge** 是面向 Intel Arrow Lake-HX Xe-LPG 核显的 macOS 图形与内屏接管实验项目。当前实机为 Intel Core Ultra 9 275HX，核显设备号为 `8086:7D67`，系统为 macOS Tahoe 26.7.1。项目已经打通 XeGfx 内核驱动、ANV Vulkan、XeMTL Metal、WindowServer 桌面合成与内屏显示链路，并把工作重点推进到刷新节拍、原生翻页、硬件光标与电源管理。

项目以单机实测为边界。仓库保存经过验证的补丁、安装脚本、试验脚本与技术记录，上游源码从对应项目获取。同机 OpenCore 配置见 [YaoShi16-Ultra-OpenCore-efi](https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi)。

## 启动方式与工作机制

当前路线采用分阶段接管。系统先完整进入 macOS，再逐层启动 GPU、图形 API 与显示通路。每一层都有明确的上游来源与职责。

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

6. **XeGfxIntelFB 发布真实面板信息**

   使用 NvGfx xe 分支中的 `XeGfxIntelFB` 模块读取 BAR0 显示寄存器和帧计数器，取得真实面板时序。当前实测模式为 2560x1600，像素时钟 276871248 Hz，扫描频率 59.877 Hz。

   ArrowBridge 在这一层补充 mode information 与 detailed timing，使 CoreDisplay 能够获得面板真实参数。

7. **NVRMAGDC 打开 IOPresentment 显示事务**

   使用 NvGfx xe 分支中的 `NVRMAGDC` 模块回答 K5 link-config 命令 `0x921`，把 XeGfxIntelFB 测得的 timing 交给显示控制链。AGDC 完成握手后，IOPresentment 开始向 head 4 发送 display-pipe transaction。

8. **display-pipe 把 WindowServer 帧送到真实内屏**

   WindowServer 先把一帧合成到 IOSurface。XeGfxAccel 收到 display-pipe transaction 后等待下一次 vblank，再把这一帧写入 firmware framebuffer aperture。显示引擎持续扫描同一块 aperture，新的桌面内容随后进入内屏。

   当前这条路径仍使用每帧约 16 MB 的 CPU copy。连续 present 已经验证完成，下一步正在推进零拷贝，让显示引擎直接扫描 surface backing，把整帧 CPU copy 从主路径中移走。

## 推进过程中解决的问题

下面按照前面的链路顺序记录关键问题与修正。每一项都对应仓库中的一个补丁或一组验证脚本。

### 1. userptr 页释放竞态

GPU workload 稳定运行后，i915 在 GEM userptr 对象回收阶段触发过：

```text
xegfx: vm: freeing wired page 0x... ref 0x1
```

调用链进入 `i915_gem_userptr_put_pages`、`linux_release_pages` 与 `xg_bsd_vm_page_free`。进一步检查发现，page hold 与最后一次 unwire 分处两个临界区。最后一个引用准备释放时，新的 pin 仍有机会重新进入同一页，最终形成带 wiring 的释放状态。

ArrowBridge 在 `0001-xg_vm-userptr-race.patch` 中把 userptr page hold 与末次 unwire 统一到同一套状态机，并加入私有 `XG_VPO_USERHOLD` 标记。最后一次 unwire 负责摘除 run 和释放页，page lifetime 因而保持单向收敛。

修正后的 40 分 08 秒压力测试完成 527696 次 churn，创建和释放 1583088 个 IOSurface，`panic_hit = 0`，`reboot_hit = 0`。

### 2. 只读 host pointer 导致 device lost

WindowServer 会交给 XeMTL 一部分只读 host mapping。早期插件直接把这些地址作为可写 external host memory 导入 ANV，随后 i915 以 `FOLL_WRITE` 语义 pin userptr。只读 VMA 在这一阶段返回失败，execbuffer 最终得到 EFAULT，ANV 再把状态上送为 `VK_ERROR_DEVICE_LOST`。

ArrowBridge 在 `0006-plugin-host-import.patch` 中加入 `nvmtl_range_writable` 判定。可写范围继续使用 host import，其余范围进入 copy path。这样让 userptr 权限与实际 VMA 权限保持一致。

修正后，连续桌面试验跨越多次启动保持稳定，原来的 execbuffer EFAULT 与 device lost 主链已经消失。

### 3. display-pipe 事务需要完整的显示握手

Metal 合成打通以后，下一步是让 WindowServer 的帧稳定进入 Intel 内屏。这里需要同时满足 framebuffer 发布、head 注册、AGDC link-config 与 IOPresentment transaction 四个条件。

ArrowBridge 在 `0002-accel-vblank-and-head4.patch` 中注册 head 4，并把 present 放到真实面板 vblank 之后。随后在 `0003-intelfb-panel-timing.patch` 中发布实时测得的面板 timing，再由 `0004-agdc-k5-panel-timing.patch` 回答 K5 link-config。

一次完整试验记录到：

- `heads_published = 16`
- `heads_registered = 16`
- `heads_piped = 16`
- `iop_ok_h4 = 2083`
- `pipe_perform = 2083`

这些计数全部落在 head 4，说明 WindowServer 到内屏的连续 present 链已经成立。

### 4. 系统刷新节拍与真实面板扫描频率分离

面板寄存器和帧计数器给出的真实扫描频率为 59.877 Hz，而 CoreDisplay 早期读取到的 mode refresh 为 0，CVDisplayLink 则按 30 Hz 推进。

ArrowBridge 先从 BAR0 读取 live timing，再由 XeGfxIntelFB 补充 `getInformationForDisplayMode` 与 `getTimingInfoForDisplayMode`。同一份 timing 同时进入 framebuffer mode information 与 AGDC K5 回答。

当前这一步已经完成代码接入，最新 kext 的运行时验证正在继续。目标是让 CGDisplayMode 与 CVDisplayLink 都收敛到面板真实节拍。

### 5. 每帧 16 MB copy 的性能边界已经量化

当前 display-pipe 使用 IOSurface 到 framebuffer aperture 的整帧 copy。2560x1600 XRGB 一帧为 16384000 字节。

实测平均 copy 耗时约 2.26 ms，平均 transaction 耗时约 11.1 ms。桌面 present 频率主要受 WindowServer 合成节拍影响。当前一边继续修正 30 Hz timing 与 display link，一边推进零拷贝显示路径。

零拷贝路线的目标是让显示引擎直接扫描可见的 surface backing，并在 vblank 边界完成切换。这样可以把整帧 CPU copy 从主路径中移走，并把 display-pipe 从过渡搬运路径推进到真正的 surface 直出。

## 硬件与系统

| 项目 | 取值 |
| --- | --- |
| 机型 | MECHREVO Yaoshi 16 Ultra |
| CPU | Intel Core Ultra 9 275HX · Arrow Lake-HX |
| 核显 | Intel Xe-LPG · 8086:7D67 |
| 独显 | NVIDIA GeForce RTX 5080 Laptop |
| 内存 | 64 GB |
| 系统 | macOS Tahoe 26.7.1 · 25G241 |
| 内核 | Darwin 25.6.0 |
| 内置屏 | 2560x1600 · 59.877 Hz 实测扫描 |

## 补丁结构

| 补丁 | 基线 | 作用 |
| --- | --- | --- |
| `0001-xg_vm-userptr-race.patch` | XeGfx 0.0.44 | 修正 userptr page lifetime |
| `0002-accel-vblank-and-head4.patch` | XeGfx 0.0.44 | 注册 head 4 并按 vblank present |
| `0003-intelfb-panel-timing.patch` | XeGfx 0.0.44 | 测量并发布真实面板 timing |
| `0004-agdc-k5-panel-timing.patch` | XeGfx 0.0.44 | 回答 AGDC K5 link-config |
| `0005-plugin-xemtl-port.patch` | XeGfx 0.0.35 plugin | 把插件改编为 XeMTL |
| `0006-plugin-host-import.patch` | XeMTL | 修正只读 host import |
| `0007-plugin-first-loss-journal.patch` | XeMTL | 记录首个 submit 与 backend failure |

补丁的应用顺序与基点提交见 [patches/README.md](patches/README.md)。

## 构建与试验

1. 克隆 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe)。
2. core 检出 `5a19a73f`，依次应用 `0001` 到 `0004`。
3. plugin 检出 `497d521e`，依次应用 `0005` 到 `0007`。
4. 使用 `build/nvgfx/build_xegfx.sh` 构建 XeGfx core。
5. 使用对应构建入口生成 XeGfxAccel、XeGfxIntelFB、NVRMAGDC 与 XeMTL。
6. 使用 `scripts/install_core_044.py`、`install_upstream_accel.py` 与 `install_xeintelfb.py` 安装并重建 AuxKC。
7. 系统启动后运行 `scripts/run_upstream_trial4.sh`，按阶段加载 core、打开 head 4、启动 display-pipe、重启一次 WindowServer 并采集遥测。
8. 使用 `scripts/soak_userptr_test.sh` 做 userptr 长压测，使用 `scripts/tools/display_probe.c` 检查刷新节拍。

完整构建说明见 [docs/building.md](docs/building.md)。

## 文档

- [显示接管路线](docs/route.md)
- [device lost 修正](docs/device-lost.md)
- [userptr panic 修正](docs/userptr-panic.md)
- [刷新率链路](docs/refresh.md)
- [硬件光标计划](docs/cursor.md)
- [帧路径性能](docs/performance.md)
- [XeMTL 插件说明](docs/plugin.md)

## 安全回退

显示接管直接操作真实 GPU 与内屏通路，因此试验流程保留三级回退。

- `-xeintelfboff` 让 framebuffer 接管停留在固件路径
- `xeintelfb-starts` 记录连续异常启动次数，并在达到阈值后让 probe 留在安全阶段
- `debug.xegfxaccelfb=1` 作为 head 4 接管开关，重启后回到默认状态

安装脚本会在 AuxKC 重建前保存现有文件，便于恢复上一套可启动配置。

## 许可与致谢

`patches/` 是对 NvGfx 与 XeGfx 上游源码的修改，沿用 PolyForm Noncommercial License 1.0.0。全文见 [LICENSE](LICENSE)。

`scripts/`、`docs/`、`README.md` 与 `NOTICE.md` 以 MIT 许可发布。全文见 [LICENSE-MIT](LICENSE-MIT)。

驱动主体来自 NullMoth Systems 的 macOS Metal 驱动体系。ArrowBridge 使用 [watchthelight-labs/NvGfx 的 xe 分支](https://github.com/watchthelight-labs/NvGfx/tree/xe) 与 [watchthelight-labs/XeGfx](https://github.com/watchthelight-labs/XeGfx)，并使用 Mesa ANV、metal2vulkan、FreeBSD drm-kmod 与 Intel GuC firmware。完整来源与署名见 [NOTICE.md](NOTICE.md)。

ArrowBridge 的适用范围以当前实机验证结果为准。
