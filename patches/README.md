# patches/ —— 改动补丁系列

本目录把项目里实际验证过的改动整理成二十二个可以按序应用的补丁。每个补丁开头的注释写明了基点提交、涉及文件、应用命令与改动意图，补丁体本身保持标准 unified diff，`a/` 与 `b/` 前缀可以直接配合 `patch -p1` 或 `git apply`。

## 应用顺序与基点

| 序号 | 补丁 | 基点 | 涉及文件 |
| --- | --- | --- | --- |
| 0001 | `0001-xg_vm-userptr-race.patch` | NvGfx `xe` `5a19a73f`（XeGfx 0.0.44） | `gpu/xegfx/shim/src/fbsd/xg_vm.c` |
| 0002 | `0002-accel-vblank-and-head4.patch` | NvGfx `xe` `5a19a73f`（0.0.44） | `kexts/NVRM/accel/nvrm-accel.cpp`，新增 `kexts/NVRM/accel/xegfx_accel_names.h` |
| 0003 | `0003-intelfb-panel-timing.patch` | NvGfx `xe` `5a19a73f`（0.0.44） | `kexts/XeGfxIntelFB/intelfb.cpp`，新增 `xe/firmware-timing.h`、`xe/panel-timing.h`、`nvrm-agdc-k5.h` |
| 0004 | `0004-agdc-k5-panel-timing.patch` | NvGfx `xe` `5a19a73f`（0.0.44） | `kexts/NVRMAGDC/nvrm-agdc.cpp`、`kexts/NVRMAGDC/xe/Info.plist`，新增 `xe/firmware-timing.h`、`xe/panel-timing.h` |
| 0005 | `0005-plugin-xemtl-port.patch` | NvGfx `xe` `497d521e`（XeGfx 0.0.35）的 `plugin/` | 插件目录整体改编 |
| 0006 | `0006-plugin-host-import.patch` | 本系列 0005 之后的插件树 | `plugin/nvmtl_vk.c` |
| 0007 | `0007-plugin-first-loss-journal.patch` | 本系列 0006 之后的插件树 | 新增 `plugin/nvmtl_first_loss.h`；修改 `plugin/nvmtl_vk.c`、`plugin/nvmtl_vk.h`、`plugin/XeMTLDevice.m` |
| 0008 | `0008-core-ggtt-flip-slots.patch` | NvGfx `xe` `5a19a73f`（0.0.44），在 0001 之后 | 修改 `gpu/xegfx/shim/include/xg_i915.h`、`gpu/xegfx/shim/src/xnu/xg_kext.cpp`、`gpu/xkpi/src/i915/xg_i915_exec.c`；新增 `gpu/xkpi/src/i915/xg_i915_flip.c` |
| 0009 | `0009-accel-zero-copy-flip.patch` | 本系列 0002 之后的加速器文件 | `kexts/NVRM/accel/nvrm-accel.cpp`、`kexts/NVRM/accel/xegfx_accel_names.h` |
| 0010 | `0010-intelfb-detailed-timings.patch` | 本系列 0003 之后的 framebuffer 文件 | `kexts/XeGfxIntelFB/intelfb.cpp` |
| 0011 | `0011-core-native-display-m0-m4a.patch` | 0.0.44，在 0001、0008 之后 | `gpu/xegfx/shim/src/xnu/xg_kext.cpp`、`gpu/xegfx/shim/include/xg_i915.h`、`gpu/xkpi/src/i915/xg_i915_flip.c`、`gpu/xkpi/exclude.txt`；新增 `gpu/xkpi/src/i915/{xg_display_hook.c,xg_display_hook.h,intel_bios.c,intel_display_driver.c}`；构建脚本路径可配置 |
| 0012 | `0012-accel-m3d-m4a-present-bootarm.patch` | 本系列 0009 之后的加速器文件 | `kexts/NVRM/accel/{nvrm-accel.cpp,nvaccel_stubs.h,xegfx_accel_names.h,xe/Info.plist}` |
| 0013 | `0013-agdc-m3d-in-kernel-arm.patch` | 本系列 0004 之后的 AGDC | `kexts/NVRMAGDC/nvrm-agdc.cpp`、`xe/Info.plist`；删除 `xe/firmware-timing.h`、`xe/panel-timing.h` |
| 0014 | `0014-intelfb-l0-ready.patch` | 本系列 0010 之后的 framebuffer 文件 | `kexts/XeGfxIntelFB/intelfb.cpp` |
| 0015 | `0015-adapter-xegfxdisplay-kms.patch` | 无（新增，适配器 b4e22af6） | 新增 `kexts/XeGfxDisplay/{Info.plist,src/XeGfxDisplay.h,src/XeGfxDisplay.cpp,src/xegfx_kms_kapi.h}` |
| 0016 | `0016-tools-native-display-bringup.patch` | 无（新增） | 新增 `tools/` 下的 M0–M4a 启动、安装与守护脚本 |
| 0017 | `0017-agdc-pending-retry.patch` | 本系列 0013 之后的 AGDC（XeGfxAGDC 43dfb951） | `kexts/NVRMAGDC/nvrm-agdc.cpp` |
| 0018 | `0018-adapter-intel-class-name.patch` | 本系列 0015 之后的适配器 | `kexts/XeGfxDisplay/src/XeGfxDisplay.{h,cpp}`、`Info.plist` |
| 0019 | `0019-guard-tools-class-name-and-keep-armed.patch` | 本系列 0016 之后的 tools/ | `tools/m3db-health.py`、`xegfx-ws-preflight.py`、`m4a2-verify.sh`、`m3db-preflight.sh`、`m3db-control.py` |
| 0020 | `0020-core-aux-edid-dpcd.patch` | 本系列 0011 之后的 core（94278c72） | `gpu/xkpi/src/i915/xg_display_hook.{c,h}`、`gpu/xegfx/shim/src/xnu/xg_kext.cpp` |
| 0021 | `0021-adapter-edid-ddc.patch` | 本系列 0018 之后的适配器 | `kexts/XeGfxDisplay/src/XeGfxDisplay.{h,cpp}` |
| 0022 | `0022-core-k1-staged-edp-takeover.patch` | 本系列 0020 之后的 core | `gpu/xegfx/shim/src/xnu/xg_kext.cpp`、`gpu/xkpi/src/i915/{xg_display_hook.c,xg_display_hook.h,intel_bios.c,intel_display_driver.c}`、`gpu/xkpi/exclude.txt`；新增 `gpu/xkpi/src/i915/intel_modeset_setup.c` |

上游精简取法：`git clone --branch xe https://github.com/watchthelight-labs/NvGfx` 后检出两个提交；0.0.44 的提交是 `5a19a73f36249efb99c44c3f9cb34603ef0c0eb8`，0.0.35 的提交是 `497d521e925bd760c8cde5bbc17d9bf96d2ee2b4`。

## 应用方法

在 0.0.44 的源码树根目录依次应用前四个补丁，再补上零拷贝与 detailed timings 的三个补丁（0008 建立在 0001 之上、0009 建立在 0002 之上、0010 建立在 0003 之上）：

```sh
cd NvGfx-5a19a73
patch -p1 < /path/to/patches/0001-xg_vm-userptr-race.patch
patch -p1 < /path/to/patches/0002-accel-vblank-and-head4.patch
patch -p1 < /path/to/patches/0003-intelfb-panel-timing.patch
patch -p1 < /path/to/patches/0004-agdc-k5-panel-timing.patch
patch -p1 < /path/to/patches/0008-core-ggtt-flip-slots.patch
patch -p1 < /path/to/patches/0009-accel-zero-copy-flip.patch
patch -p1 < /path/to/patches/0010-intelfb-detailed-timings.patch
```

原生显示栈（0011–0022）接着叠在同一棵 0.0.44 树上。0011–0016 是此前只在本机 native-display 工作区存在的基点（core 的 M0–M4a 显示钩子、加速器、AGDC、IntelFB、XeGfxDisplay 适配器与脚本），0017–0022 是在它之上的修复：

```sh
for n in 0011 0012; do patch -p1 < /path/to/patches/$n-*.patch; done
patch -p1 -E < /path/to/patches/0013-agdc-m3d-in-kernel-arm.patch
for n in 0014 0015 0016 0017 0018 0019 0020 0021 0022; do patch -p1 < /path/to/patches/$n-*.patch; done
```

`0013` 删除 0004 加入的两个时序头文件，带 `-E` 才会把清空的文件一并删掉。

插件补丁换成 0.0.35 的源码树，按 0005、0006、0007 的顺序应用：

```sh
cd NvGfx-497d521
patch -p1 --remove-empty-files < /path/to/patches/0005-plugin-xemtl-port.patch
patch -p1 < /path/to/patches/0006-plugin-host-import.patch
patch -p1 < /path/to/patches/0007-plugin-first-loss-journal.patch
```

`0005` 里 `plugin/NVMTLDevice.m` 被删除、`plugin/XeMTLDevice.m` 被加入，因此应用时带 `--remove-empty-files` 更干净。

两套补丁的基点互不通用：`0001–0004`、`0008–0022` 针对 0.0.44 树，`0005–0007` 针对 0.0.35 的 `plugin/` 目录。把插件补丁叠到 0.0.44 树上时，`0006` 会因为上下文差异出现部分 hunk 失败，这属于基点混用而不是补丁本身的问题；在 0.0.35 树上重放 `0005 → 0006 → 0007` 三个补丁全部 `OK`（最终 `plugin/` 33 个文件，`nvmtl_range_writable` 标记存在）。

## 验证方式

项目在生成补丁时对每个补丁做了两向验证：

1. 把补丁应用到对应基点的干净源码树，再与项目里实际参与编译的源码目录做逐文件比对
2. 对插件系列验证三点闭环：0.0.35 干净插件树 + 0005 + 0006 + 0007 等于项目里的插件源码树

四个 kext 补丁的比对目标是：`xg_vm.c` 对照 core 树，`nvrm-accel.cpp` 与 `xegfx_accel_names.h` 对照 accel 树，`intelfb.cpp` 与三个新头文件对照 framebuffer 树，AGDC 的四项对照 AGDC 树。验证结果全部一致，验证脚本只在本机运行过，没有放进仓库。

零拷贝与 detailed timings 的三个补丁（0008–0010）同样在 0.0.44 干净树上验证：先应用 0001、0002、0003，再应用 0008、0009、0010，全部 `OK`；应用后 `xg_i915_flip.c`（新增）、`nvrm-accel.cpp`、`intelfb.cpp` 与项目工作树逐字节一致。这一组验证没有依赖 0004–0007（AGDC 与插件补丁，与这三个文件无关）。

原生显示栈 0011–0022 也在同一棵干净树上验证：0001–0004、0008–0010 之后依次应用 0011–0016，结果与本机的会话前工作树逐文件一致；再应用 0017–0022，`gpu/xkpi`、`xg_kext.cpp`、`xg_i915.h` 与 core 源码树一致，加速器、AGDC、IntelFB 与当前编译用的 kext 源码一致，适配器与当前安装的 XeGfxDisplay 源码一致，全部 `OK`、没有 `.rej`。脚本不再依赖开发机的日期工作目录：仓库内 `tools/` 互相引用时从脚本自身位置解析，仓库外源码树与构建产物通过 `XEGFX_*` 环境变量显式指定；`/Library`、`/System`、`/usr` 等系统路径保持绝对路径。

补丁不包含绝对路径、时间戳无关的行号偏移，也不包含构建产物。补丁可以重复生成，生成的源头是第 2 节列出的两个上游提交以及本机项目树。
