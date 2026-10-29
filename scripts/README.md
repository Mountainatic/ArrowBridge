# scripts/ —— 安装、试验与压测脚本

本目录收录项目里实际使用过的脚本与两个小工具源码。仓库内文件一律从脚本自身位置定位；仓库外的源码树、helper 与 kext 构建产物必须通过 `XEGFX_*` 环境变量显式指定，不再猜测开发机上的日期工作目录。系统安装目标（如 `/Library/Extensions`、`/Library/XeGfxTrial`）仍使用固定绝对路径。

## 目录

| 文件 | 用途 |
| --- | --- |
| `install_core_044.py` | 安装 XeGfx 0.0.44 core kext（磁盘层），并用 `kmutil` 重建 AuxKC |
| `install_upstream_accel.py` | 安装 XeGfxAccel（head-4 启动 framebuffer 与 display-pipe 通路），把暂存的 `Info.plist` 指向本机的 XeMTL 插件类名 |
| `install_xeintelfb.py` | 安装 XeGfxIntelFB（Intel 类名的 `IONDRVFramebuffer` 子类），重建 AuxKC |
| `run_upstream_trial4.sh` | 一次完整的桌面试验：加载 core、加载 accel、headless 阶段、开启 head 4 与 display-pipe、单次 WindowServer 重启、采集遥测 |
| `soak_userptr_test.sh` | 长时间图形负载与取证：起停 `ca_bench2`、常驻 `soak_surface_churn`、采样遥测、比对 panic 与 boot 身份 |
| `tools/ca_bench2.m` | CoreAnimation 动画窗口负载，驱动 WindowServer 反复 present |
| `tools/soak_surface_churn.m` | IOSurface / layer 内容高速创建与丢弃，制造 userptr pin/unpin 抖动 |
| `tools/display_probe.c` | 打印主显示器的 CGDisplayMode 刷新率与 CVDisplayLink 名义刷新周期，用来核对刷新率修复 |

## 环境变量

路径变量统一使用 `XEGFX_*` 前缀。外部输入没有隐藏的本机默认值：

| 变量 | 脚本 | 作用 |
| --- | --- | --- |
| `XEGFX_CORE_KEXT` | `install_core_044.py` | **必填**，待安装的 `XeGfx.kext` 构建产物 |
| `XEGFX_ACCEL_KEXT` | `install_upstream_accel.py` | **必填**，待安装的 `XeGfxAccel.kext` 构建产物 |
| `XEGFX_INTELFB_KEXT` | `install_xeintelfb.py` | **必填**，待安装的 `XeGfxIntelFB.kext` 构建产物 |
| `XEGFX_PROJECT_ROOT` | `run_upstream_trial4.sh`、`run_upstream_trial5.sh` | **必填**，外部项目/构建树；其中应存在 `build/tools/display-route-snapshot` |
| `XEGFX_HELPER_DIR` | `run_upstream_trial4.sh`、`run_upstream_trial5.sh` | **必填**，包含 `continue_headless_stage4_7.py` 的 helper 目录 |
| `XEGFX_TRIAL_ROOT` | trial 脚本 | 试验输出目录，默认 `/Library/XeGfxTrial` |
| `XEGFX_TOOLS_DIR` | `soak_userptr_test.sh` | 负载程序源码目录，默认当前仓库的 `scripts/tools/` |

## 未随仓库提供的依赖

以下内容不随本仓库提供，运行时需要从对应的外部源码/构建树显式指定：

- `continue_headless_stage4_7.py`：core kext 的 headless 阶段推进脚本，`run_upstream_trial4.sh` 在 `XEGFX_HELPER_DIR` 下寻找
- `build/tools/display-route-snapshot`、`build/tools/drm*` 等 display 与 DRM 探针，trial 脚本通过 `XEGFX_PROJECT_ROOT` 定位
- 已编译的 kext：三个安装脚本需要现成的 `.kext` 目录，编译方法见 `docs/building.md`
- 已编译的 `/Library/GPUBundles/XeMTLDriver.bundle`：加速器需要一个 Metal 插件，源码由补丁 0005 到 0007 生成

## 运行前提

三个安装脚本与试验脚本需要 root，并且只在一台已经装好上游 NvGfx 驱动、能正常启动的测试机上使用。两个负载工具与 display probe 以普通用户身份在图形会话里运行。

- 安装脚本会备份 `AuxiliaryKernelExtensions.kc` 与目标 kext，再用 `kmutil create` 生成新的 AuxKC，失败时会回滚
- 安装与试验都在重启后生效；`run_upstream_trial4.sh` 会删除上一次试验残留的 `/Library/GPUBundles/xemtl-allow.txt` 与 `/private/tmp/xemtl-first-loss-enable`
- 试验脚本里的单次 WindowServer 重启是必要的：head 4 帧缓冲与 display-pipe 通路都在 WindowServer 启动时注册

## 编译小工具

两个 Objective-C 工具与一个 C 探针都用系统自带的 Command Line Tools 直接编译：

```sh
clang -O2 -framework Cocoa -framework QuartzCore \
      -o /tmp/ca_bench2 scripts/tools/ca_bench2.m
clang -O2 -framework Cocoa -framework QuartzCore -framework IOSurface \
      -framework Metal -framework CoreVideo \
      -o /tmp/soak_surface_churn scripts/tools/soak_surface_churn.m
clang -O2 -framework ApplicationServices -framework CoreVideo \
      -o /tmp/display_probe scripts/tools/display_probe.c
```

## 语法检查

仓库提交前对脚本做过静态检查：`bash -n` 覆盖 `run_upstream_trial4.sh` 与 `soak_userptr_test.sh`，`python3 -m py_compile` 覆盖三个安装脚本；全部通过。安装脚本带 `#!/usr/bin/env python3` 与可执行位，`soak_userptr_test.sh` 使用 bash 语法，解释器取 bash。
