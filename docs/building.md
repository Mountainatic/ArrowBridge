# 构建、安装与验证流程

## 源码基点

ArrowWhatever 使用两套 NvGfx `xe` 源码：

| 源码范围 | 提交 | 版本 |
| --- | --- | --- |
| XeGfx core 与显示组件 | `5a19a73f36249efb99c44c3f9cb34603ef0c0eb8` | XeGfx 0.0.44 |
| XeMTL `plugin/` | `497d521e925bd760c8cde5bbc17d9bf96d2ee2b4` | XeGfx 0.0.35 |

组件补丁链：

| 组件 | 补丁链 |
| --- | --- |
| XeGfx core / xkpi | `0001 → 0008 → 0011 → 0020 → 0022` |
| XeGfxAccel | `0002 → 0009 → 0012` |
| XeGfxIntelFB | `0003 → 0010 → 0014` |
| XeGfxAGDC | `0004 → 0013 → 0017` |
| XeGfxDisplay | `0015 → 0018 → 0021` |
| native-display tools | `0016 → 0019` |
| XeMTL | `0005 → 0006 → 0007` |

完整逐补丁前置状态与应用命令见 [../patches/README.md](../patches/README.md)。

## 构建依赖

- macOS Tahoe 26.7.1 与 Xcode Command Line Tools
- XeGfx 构建所需的 Linux/i915、FreeBSD、drm-kmod 与 firmware 源码
- kcabi 检查工具
- XeGfxAccel 构建所需的 NVIDIA Open GPU Kernel Modules 源码
- XeMTL 构建所需的 Vulkan-Headers 与 translator 组件
- 安装与 AuxKC 重建所需的管理员权限

外部源码目录由 `XEGFX_SRC`、`XEGFX_KCABI`、`XEGFX_NVGFX_ROOT`、`XEGFX_BUILD_ROOT` 等环境变量传入。仓库内工具通过脚本自身位置定位。

## 构建产物

一次完整部署包含五个 kext 与一个 Metal plugin bundle：

| 产物 | 补丁链 | 作用 |
| --- | --- | --- |
| `XeGfx.kext` | `0001 → 0008 → 0011 → 0020 → 0022` | GPU core、boot-arm、VBT/KMS、AUX、K1 eDP readout |
| `XeGfxAccel.kext` | `0002 → 0009 → 0012` | display-pipe、zero-copy present、adapter/accel contract |
| `XeGfxIntelFB.kext` | `0003 → 0010 → 0014` | panel timing、detailed timing、L0 ready |
| `XeGfxAGDC.kext` | `0004 → 0013 → 0017` | AGDC/K5 与启动阶段显示映射 |
| `XeGfxDisplay.kext` | `0015 → 0018 → 0021` | KMS framebuffer adapter、scanout、EDID/DDC |
| `XeMTLDriver.bundle` | `0005 → 0006 → 0007` | Metal → Vulkan/ANV |

## 构建 XeGfx core

在 0.0.44 源码树完成 core 补丁链后执行：

```sh
bash build/nvgfx/build_xegfx.sh
```

构建流程包含源文件覆盖检查、KPI 符号检查、shadow 检查与 kcabi 检查，产物位于：

```text
gpu/xegfx/out/XeGfx.kext
```

## 构建显示组件

XeGfxIntelFB 与 XeGfxAGDC：

```sh
bash build/nvgfx/build_xegfxintelfb.sh
bash build/nvgfx/build_xegfxagdc.sh
```

XeGfxAccel：

```sh
bash build/accel_build.sh
```

XeGfxDisplay：

```sh
bash tools/build-xegfxdisplay.sh
```

`SDKROOT` 可以指定当前 Command Line Tools 提供的 macOS SDK。

## 构建 XeMTL

在 `497d521e` 的 `plugin/` 树应用 `0005 → 0006 → 0007`，随后构建 translator 与 plugin：

```sh
bash build/nvgfx/build_xlate.sh
bash build/nvgfx/build_plugin.sh
```

最终 bundle 为：

```text
XeMTLDriver.bundle/Contents/MacOS/XeMTLDriver
```

Metal personality使用：

```text
MetalPluginName      = ../../../Library/GPUBundles/XeMTLDriver
MetalPluginClassName = XeMTLDevice
```

## 安装与 AuxKC

0016 工具集提供产物检查、事务安装、AuxKC 重建、bootguard、health 与 rollback。

安装前先运行：

```sh
bash tools/preflight-m3d.sh
```

`tools/install-m3d.py` 接受五个 kext 的显式路径：

```sh
sudo python3 tools/install-m3d.py \
  --core    /path/to/XeGfx.kext \
  --adapter /path/to/XeGfxDisplay.kext \
  --accel   /path/to/XeGfxAccel.kext \
  --agdc    /path/to/XeGfxAGDC.kext \
  --intelfb /path/to/XeGfxIntelFB.kext
```

安装事务依次完成 bundle 检查、暂存、ad-hoc 签名、`/Library/Extensions` 更新与 AuxiliaryKernelExtensions.kc 重建，并把备份与状态记录写入 `/Library/XeGfxTrial`。

XeMTL 安装到：

```text
/Library/GPUBundles/XeMTLDriver.bundle
```

## 启动配置

boot-arm 负责启动阶段的 XeGfx stage 1–7 与后续显示组件衔接。K1 eDP readout 使用：

```text
xegfx-disp-kms=1
```

启动链依次形成：

```text
XeGfx stage 1–7
→ XeGfxDisplayNub
→ AUX EDID/DPCD
→ K1 eDP readout
→ XeGfxDisplay framebuffer / scanout
→ XeGfxAccel
→ XeGfxAGDC / K5
→ WindowServer / XeMTL / ANV
→ display-pipe
```

## 启动后验证

`tools/m4a2-verify.sh` 采集 kext、IOFramebuffer、claim node、core、display nub、accel、Metal、用户态与内核日志：

```sh
bash tools/m4a2-verify.sh --strict
```

重点检查：

- XeGfx stage 1–7 完成状态
- `XeGfxDisplayNub` 与 KMS KAPI
- EDID/DPCD 发布状态
- K1 connector、fixed mode、CRTC 与活动 pipe readout
- `XeGfxIntelKMSFramebuffer` 与 scanout
- XeGfxAccel head / pipe / present 计数
- AGDC/K5 映射状态
- WindowServer 的 XeMTL Metal 枚举与 display-pipe 提交

K1 的当前试验范围是 eDP 状态读取。modeset、HBR3、DSC 与 240 Hz 沿同一显示链继续推进。

## 稳定性与回归

userptr 与图形负载使用：

```sh
bash scripts/soak_userptr_test.sh
```

刷新节拍和模式列表使用 `scripts/tools/display_probe.c` 等探针。bootguard、health 输出、统一日志与 `/Library/XeGfxTrial` 中的事务记录用于启动链回归。

## 回滚

安装事务在 `/Library/XeGfxTrial` 保存 kext、AuxKC 与状态记录。0016 提供对应 rollback 工具恢复安装前状态；bootguard 同时记录每次 claim boot 的健康结果。
