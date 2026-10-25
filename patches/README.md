# patches/ —— 改动补丁系列

本目录把项目里实际验证过的改动整理成七个可以按序应用的补丁。每个补丁开头的注释写明了基点提交、涉及文件、应用命令与改动意图，补丁体本身保持标准 unified diff，`a/` 与 `b/` 前缀可以直接配合 `patch -p1` 或 `git apply`。

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

上游精简取法：`git clone --branch xe https://github.com/watchthelight-labs/NvGfx` 后检出两个提交；0.0.44 的提交是 `5a19a73f36249efb99c44c3f9cb34603ef0c0eb8`，0.0.35 的提交是 `497d521e925bd760c8cde5bbc17d9bf96d2ee2b4`。

## 应用方法

在 0.0.44 的源码树根目录依次应用前四个补丁：

```sh
cd NvGfx-5a19a73
patch -p1 < /path/to/patches/0001-xg_vm-userptr-race.patch
patch -p1 < /path/to/patches/0002-accel-vblank-and-head4.patch
patch -p1 < /path/to/patches/0003-intelfb-panel-timing.patch
patch -p1 < /path/to/patches/0004-agdc-k5-panel-timing.patch
```

插件补丁换成 0.0.35 的源码树，按 0005、0006、0007 的顺序应用：

```sh
cd NvGfx-497d521
patch -p1 --remove-empty-files < /path/to/patches/0005-plugin-xemtl-port.patch
patch -p1 < /path/to/patches/0006-plugin-host-import.patch
patch -p1 < /path/to/patches/0007-plugin-first-loss-journal.patch
```

`0005` 里 `plugin/NVMTLDevice.m` 被删除、`plugin/XeMTLDevice.m` 被加入，因此应用时带 `--remove-empty-files` 更干净。

## 验证方式

项目在生成补丁时对每个补丁做了两向验证：

1. 把补丁应用到对应基点的干净源码树，再与项目里实际参与编译的源码目录做逐文件比对
2. 对插件系列验证三点闭环：0.0.35 干净插件树 + 0005 + 0006 + 0007 等于项目里的插件源码树

四个 kext 补丁的比对目标是：`xg_vm.c` 对照 core 树，`nvrm-accel.cpp` 与 `xegfx_accel_names.h` 对照 accel 树，`intelfb.cpp` 与三个新头文件对照 framebuffer 树，AGDC 的四项对照 AGDC 树。验证结果全部一致，验证脚本只在本机运行过，没有放进仓库。

补丁不包含绝对路径、时间戳无关的行号偏移，也不包含构建产物。补丁可以重复生成，生成的源头是第 2 节列出的两个上游提交以及本机项目树。
