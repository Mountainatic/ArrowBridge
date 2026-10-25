# ArrowBridge

**ArrowBridge** 是面向 Arrow Lake-HX Xe-LPG 核显的 macOS 图形与显示通路实验项目。本仓库记录一台 hackintosh 笔记本把桌面合成与内置屏显示交给 Intel 核显的过程，内容包括在上游 NvGfx / XeGfx 之上验证过的补丁、安装与验证脚本，以及按主题整理的技术笔记。

仓库地址：<https://github.com/Mountainatic/intel-xe-lpg-igpu-macos>

同一台机器的 OpenCore EFI 配置在同主的另一个仓库：<https://github.com/Mountainatic/YaoShi16-Ultra-OpenCore-efi>

## 这个仓库是什么

这台机器的核显是 Intel Xe-LPG（设备号 `8086:7D67`），macOS 没有为它提供显示驱动。项目以 NvGfx 的 XeGfx 分支为内核侧基础，把 GPU 与显示引擎接管过来，再通过 XeMTL 插件把 Metal 接到 Vulkan/ANV，让 WindowServer 在 Intel 核显上完成桌面合成。

ArrowBridge 当前以单机实测为中心，形态是“补丁 + 脚本 + 文档”，不包含上游驱动的完整源码，也不包含 Apple 的 SDK 头文件或任何安装包。驱动基线是 NvGfx `xe` 分支的 XeGfx 0.0.44，插件线的基线是同一项目的 XeGfx 0.0.35。所有改动都以 unified diff 形式放在 `patches/`，按顺序应用即可复现项目里参与构建的源码树。

## 硬件与系统

| 项目 | 取值 |
| --- | --- |
| 机型 | MECHREVO Yaoshi 16 Ultra（hackintosh） |
| CPU | Intel Core Ultra 9 275HX（Arrow Lake-HX） |
| 核显 | Intel Xe-LPG，`8086:7D67` |
| 独显 | NVIDIA GeForce RTX 5080 |
| 内存 | 64 GB |
| 系统 | macOS Tahoe 26.7.1（25G241） |
| 内核 | Darwin 25.6.0 |
| 内置屏 | 2560x1600，像素时钟 276,871,248 Hz，实测 59.877 Hz |

## 上游来源与许可

| 上游 | 位置 | 版本/提交 | 许可 |
| --- | --- | --- | --- |
| NvGfx / XeGfx | <https://github.com/watchthelight-labs/NvGfx>，分支 `xe` | `5a19a73f36249efb99c44c3f9cb34603ef0c0eb8`（0.0.44） | PolyForm Noncommercial 1.0.0 |
| NvGfx 插件基线 | 同一仓库，分支 `xe` | `497d521e925bd760c8cde5bbc17d9bf96d2ee2b4`（0.0.35） | PolyForm Noncommercial 1.0.0 |
| NVIDIA 开放 GPU 内核模块 | <https://github.com/NVIDIA/open-gpu-kernel-modules> | 610.57.04（r610） | MIT / GPL-2.0 |

XeMTL 插件由 0.0.35 的插件目录改编，之后一直没有与 0.0.44 同步，因此插件补丁以 0.0.35 为基线，kext 补丁以 0.0.44 为基线。上游驱动的主体工作是 NullMoth Systems 的成果，第三方组件的许可与署名见 `NOTICE.md`。

## 今天能做什么

**Metal 桌面合成已经在 Intel 核显上工作。** WindowServer 把桌面绘制到 Metal，Metal 经 XeMTL 插件翻译成 Vulkan，再经 ANV 调用 core kext；整条链路在核显上完成合成，不依赖独显。

**内置屏已经由我的显示通路驱动。** 固件留下的帧缓冲被接管为显示 head 4，显示引擎持续扫描真实 aperture（LIVE SCANOUT），WindowServer 通过 display-pipe 事务把新帧写进同一块内存。一次试验里，`heads_published/registered/piped` 都是 `16`（bit 4 置位），`iop_ok_h4 = 2083`，`pipe_perform = 2083`，全部 present 都落在 head 4。

**AGDC 已经应答显示控制通道。** 加速器侧的 AGDC 角色回答 K5 link-config（命令 `0x921`），`IOPresentment` 由此开始 display-pipe 事务；试验里 `k5_link = 3`、`k5_caps = 3`、`agdc_cmds = 73`，framebuffer 映射记录完整。

**userptr 拆除路径的内核 panic 已修复并通过长压测。** 修正把页 pin 与最后一次 unwire 放进同一个临界区，用私有 `oflags` 标记位保护 userptr 页。40 分 08 秒压测完成 527,696 次 churn、创建/释放 1,583,088 个 IOSurface，`panic_hit = 0`、`reboot_hit = 0`。

**Vulkan device lost 已定位并修复。** 只读的 16 MB host pointer 曾被当成可写 i915 userptr 导入，pin 失败后设备丢失；导入前的可写性判定把这类缓冲改走复制路径。

**失败现场可以留证。** 插件带有可选的 first-loss journal，按事件记录 submit、fence、host pointer 导入与 image binding，后端丢失时只记录一次。

## 当前限制与路线图

| 项目 | 现状 | 下一步 |
| --- | --- | --- |
| 显示链路刷新率 | 系统侧仍按 30 Hz 报告，面板实际扫描 59.877 Hz | 在最新 kext 上验证模式刷新率与 detailed timing 的发布效果，见 `docs/refresh.md` |
| 光标 | 由 WindowServer 软件合成 | 接入 LPG 硬件光标通道，见 `docs/cursor.md` |
| 帧路径性能 | 每帧一次 16 MB CPU 复制到 write-combined aperture | 用翻页取代整帧复制，优化复制粒度，见 `docs/performance.md` |
| 显示通路稳定性 | LIVE SCANOUT 在真实 aperture 上运行，注册写入有可能冻结整机 | 保留启动参数与 NVRAM 计数两级回退，逐步扩大试验范围 |

## 仓库布局

```text
.
├── README.md                 本文件
├── LICENSE                   PolyForm Noncommercial License 1.0.0
├── NOTICE.md                 上游血缘、第三方组件与署名
├── patches/                  七个按序应用的 unified diff（见 patches/README.md）
│   ├── 0001-xg_vm-userptr-race.patch
│   ├── 0002-accel-vblank-and-head4.patch
│   ├── 0003-intelfb-panel-timing.patch
│   ├── 0004-agdc-k5-panel-timing.patch
│   ├── 0005-plugin-xemtl-port.patch
│   ├── 0006-plugin-host-import.patch
│   └── 0007-plugin-first-loss-journal.patch
├── scripts/                  安装、试验、压测脚本与小工具（见 scripts/README.md）
│   ├── install_core_044.py
│   ├── install_upstream_accel.py
│   ├── install_xeintelfb.py
│   ├── run_upstream_trial4.sh
│   ├── soak_userptr_test.sh
│   └── tools/
│       ├── ca_bench2.m
│       ├── soak_surface_churn.m
│       └── display_probe.c
└── docs/                     技术笔记
    ├── route.md              显示接管路线：head 4、LIVE SCANOUT、display-pipe 事务
    ├── device-lost.md        只读 host pointer 导致的 device lost 与导入判定
    ├── userptr-panic.md      userptr 拆除竞态、修正与 soak 验证
    ├── refresh.md            30 Hz 的来源与刷新率修复
    ├── cursor.md             硬件光标通路与计划
    ├── performance.md        每帧 16 MB 复制的成本模型与优化方向
    ├── building.md           构建、安装、AuxKC 重建与试验流程
    └── plugin.md             XeMTL 插件血缘与 first-loss journal
```

## 构建、安装与试验

完整步骤写在 `docs/building.md`，这里给出流程骨架：

1. **取上游源码**：克隆 NvGfx 并分别检出 0.0.44（`5a19a73f`）与 0.0.35（`497d521e`）两个提交，取法见 `patches/README.md`。
2. **应用补丁**：在 0.0.44 树上按序应用 `0001` 到 `0004`；在 0.0.35 的 `plugin/` 上按序应用 `0005` 到 `0007`。
3. **构建**：core 用 `build/nvgfx/build_xegfx.sh`，framebuffer 与 AGDC 用 `build/nvgfx/build_xegfxintelfb.sh` 与 `build/nvgfx/build_xegfxagdc.sh`，加速器与插件分别在各自的构建入口完成。
4. **安装**：用 `scripts/install_core_044.py`、`install_upstream_accel.py`、`install_xeintelfb.py` 把 kext 装进 `/Library/Extensions/`，重建 AuxKC，然后重启。
5. **试验**：用 `scripts/run_upstream_trial4.sh` 跑一次完整桌面试验（加载 kext、推进 headless 阶段、打开 head 4 与 display-pipe、单次 WindowServer 重启、采集遥测）。
6. **观测**：用 `scripts/tools/display_probe.c` 看刷新率两条路径，用 `debug.xegfxaccel_iop_*` 看帧路径成本，用 `scripts/soak_userptr_test.sh` 做长压测。

## 风险与回退

显示接管工作在真实硬件通路上，注册写入可能让机器冻结。项目为此保留了三层回退：启动参数 `-xeintelfboff` 关闭 framebuffer 接管；NVRAM 计数 `xeintelfb-starts` 在连续异常启动后让探针主动拒绝加载；加速器的 head 4 注册默认关闭，写入 `debug.xegfxaccelfb=1` 才打开，重启即恢复。安装脚本在重建 AuxKC 之前备份现有文件，失败时回滚。

## 许可与致谢

本仓库按内容分成两份许可：`patches/` 是对上游 NvGfx 源码的修改，属于上游衍生部分，沿用上游的 PolyForm Noncommercial License 1.0.0（全文见 `LICENSE`），仅限非商业用途；`scripts/`、`docs/`、`README.md`、`NOTICE.md` 这些原创内容以 MIT 许可发布（全文见 `LICENSE-MIT`），保留版权声明即可自由使用。

驱动主体来自 NullMoth Systems 的 macOS NVIDIA Metal 驱动，本项目使用 `watchthelight-labs/NvGfx` 的 `xe` 分支。内核侧的 family 与 NVRM 部分构建在 NVIDIA 开放 GPU 内核模块之上。第三方组件还包括 Mesa NVK（MIT）、metal2vulkan（作者 Anees Iqbal，LGPL-3.0 或更高版本）与 NVIDIA GSP 固件（NVIDIA 固件许可）。完整的署名与许可说明见 `NOTICE.md`。

ArrowBridge 为单机试验记录，按现状提供，不承诺适用于其他机型或系统版本。
