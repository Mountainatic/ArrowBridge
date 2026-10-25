# 构建、安装与试验流程

## 目标产物

一次完整的部署包含五个产物：

| 产物 | 来源 | 说明 |
| --- | --- | --- |
| `XeGfx.kext` | NvGfx 0.0.44 + 补丁 `0001` 到 `0004` | core kext，提供 GPU 与显示引擎的 shim 层 |
| `XeGfxAccel.kext` | XeGfx 加速器树 | 注册 head 4、执行 display-pipe 事务、提供 `debug.xegfxaccel_*` 计数器 |
| `XeGfxIntelFB.kext` | NvGfx 0.0.44 + 补丁 `0003` | `IONDRVFramebuffer` 子类，测量面板 timing 并发布 detailed timing |
| `XeGfxAGDC.kext` | NvGfx 0.0.44 + 补丁 `0004` | AGDC 角色，回答 K5 link-config（`0x921`） |
| `XeMTLDriver.bundle` | 0.0.35 插件树 + 补丁 `0005` 到 `0007` | Metal 插件，把 Metal 调用转成 Vulkan/ANV |

## 依赖

- macOS 26.7.1（25G241）与 Xcode Command Line Tools，SDK 用系统自带的版本
- NvGfx 0.0.44 源码树与 0.0.35 源码树（取法见 `patches/README.md`）
- core 构建所需的 Linux/i915 源码快照：Linux 内核源码、FreeBSD 头文件、drm-kmod 与 linux-firmware 固件，本机放在 `~/src/xe-src` 下，构建脚本从该目录读取
- accel 构建所需的 NVIDIA Open GPU Kernel Modules 610.57.04 源码（本项目使用的 XeGfx 加速器树由它派生）
- 插件构建所需的 Vulkan-Headers 与 translator 组件，二者都来自 NvGfx 树
- 安装阶段需要 root；内核扩展与插件都在重启后生效

## 构建 core

在打过前四个补丁的 0.0.44 源码树里执行：

```sh
bash build/nvgfx/build_xegfx.sh
```

脚本从 `~/src/xe-src` 收集 i915、LinuxKPI 与 drm 对象，先跑 `gpu/xegfx/harness/score.py` 核对“每一个源文件都被编进去了”，再调用 `gpu/xegfx/tools/link.sh` 做 KPI 符号、shadow 符号与 kcabi 检查。产物落在 `gpu/xegfx/out/XeGfx.kext`。

## 构建 framebuffer 与 AGDC

两个 kext 的构建入口都在 `build/nvgfx/` 下：

```sh
bash build/nvgfx/build_xegfxintelfb.sh   # -> XeGfxIntelFB/XeGfxIntelFB.kext
bash build/nvgfx/build_xegfxagdc.sh      # -> XeGfxAGDC/XeGfxAGDC.kext
```

脚本默认从 `/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk` 取 SDK，用 `clang++ -fapple-kext -mkernel -std=c++17 -fno-rtti -fno-exceptions` 编译，链接参数是 `-nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext`，最后用 ad-hoc 签名。产物根目录由 `OUTROOT` 控制。

## 构建 accel

加速器来自项目的 XeGfx 加速器树，入口在 `build/` 下：

```sh
bash build/accel_build.sh
```

产物以 `.kext` 目录形式输出到构建根目录的 `XeGfxAccel/26/` 下。安装脚本 `install_upstream_accel.py` 会在暂存阶段修改 `Info.plist` 的两个键，把 Metal 插件类名指向本机的 XeMTL 插件：

- `MetalPluginClassName = XeMTLDevice`
- `MetalPluginName = ../../../Library/GPUBundles/XeMTLDriver`

## 构建插件

插件先在 0.0.35 的干净插件树上应用补丁 `0005`、`0006`、`0007`，然后分两步构建：先构建 translator，再构建插件 bundle。

```sh
bash build/nvgfx/build_xlate.sh    # translator dylib，插件在运行期加载
bash build/nvgfx/build_plugin.sh   # XeMTLDriver.bundle
```

插件以 `clang -bundle` 方式构建，链接 `Foundation`、`Metal`、`IOSurface`、`IOKit` 与 `CoreFoundation`，输出目录布局为 `XeMTLDriver.bundle/Contents/MacOS/XeMTLDriver`，`Info.plist` 里写 `MetalPluginName = XeMTLDriver`、`MetalPluginClassName = XeMTLDevice`。构建完成后对 bundle 做 ad-hoc 签名，再复制到 `/Library/GPUBundles/XeMTLDriver.bundle`。

## 安装与 AuxKC

三个安装脚本用同一套流程：校验产物的 bundle id 与 personality，备份现有 kext 与 AuxKC，复制、设置属主与权限、重新签名，然后重建辅助内核集合。

```sh
sudo python3 scripts/install_core_044.py       # core -> /Library/Extensions/XeGfx.kext
sudo python3 scripts/install_upstream_accel.py # accel -> /Library/Extensions/XeGfxAccel.kext
sudo python3 scripts/install_xeintelfb.py      # framebuffer -> /Library/Extensions/XeGfxIntelFB.kext
```

重建 AuxKC 的核心命令来自脚本，形态如下（`-A` 逐个列出候选集合里的全部 bundle）：

```sh
kmutil create -n aux --volume-root / --allow-missing-kdk \
  -B /System/Library/KernelCollections/BootKernelExtensions.kc \
  -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
  --repository /Library/Extensions \
  --repository /Library/Apple/System/Library/Extensions \
  -A <candidate bundle> ... -z
```

脚本随后用 `kmutil inspect -a x86_64 -A` 核对候选版本，并确认没有其他 bundle 被意外改动；任何一项不符合预期都会回滚到备份的 AuxKC。AGDC 的安装沿用同一模式，把 `XeGfxAGDC.kext` 放进 `/Library/Extensions/` 后重建 AuxKC。

安装完成后重启，让新 kext 进入 AuxKC 并加载。

## 试验流程

`scripts/run_upstream_trial4.sh` 把一次完整试验串起来，步骤按顺序是：

1. 加载 core kext，设置 `debug.xegfx_env`（关闭 i915 自带显示、启用 GuC）、看门狗周期与 `debug.xegfx_stage=2`，确认阶段到位
2. 加载 accel kext，读取 `heads_published` 等计数器
3. 推进 headless 阶段 4 到 7，注册 head 4 并发布 display-pipe 能力
4. 打开 `debug.xegfx_agdc=1` 与 `debug.xegfx_agdc_k5=1`，触发面板 timing 测量，读取 `debug.xegfx_panel_probe_result`
5. 打开 `debug.xegfxaccelfb=1`、`debug.xegfxaccel_iop=1`，核对 `heads_published/registered/piped = 16`
6. 准备插件允许文件与 first-loss journal sentinel，做一次 WindowServer 重启
7. 采集 200 秒遥测、WindowServer 采样与统一日志，再收尾

关键 sysctl 分布在三个 kext：core 侧是 `debug.xegfx_*`，accel 侧是 `debug.xegfxaccel_*`，AGDC 侧是 `debug.xegfx_agdc*` 与 `debug.xegfx_panel_*`。用户态探针 `scripts/tools/display_probe.c` 与 `modes_list.c` 用来核对刷新率与模式列表。

## 回退与保护

显示通路的试验有可能在注册写入之后冻结整机，因此项目保留了三层保护：

- 启动键盘参数 `-xeintelfboff` 关闭 `XeGfxIntelFB` 的接管
- NVRAM 计数 `xeintelfb-starts` 连续两次异常启动后，framebuffer 探针主动拒绝加载，回到 Apple 的 `IONDRVFramebuffer`
- accel 的 head 4 注册默认关闭，写入 `debug.xegfxaccelfb=1` 才打开；重启即恢复默认

安装脚本回滚 AuxKC 与 kext；插件侧删除 `/Library/GPUBundles/xemtl-allow.txt` 与 `/private/tmp/xemtl-first-loss-enable` 即可回到未启用状态。
