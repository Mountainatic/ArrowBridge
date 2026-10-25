# 来源与许可说明

本仓库是一个记录性质的发布暂存区（staging tree）。其中包含 Intel Xe-LPG 核显在 macOS 上接管显示通路时产生的补丁、脚本与技术文档。仓库不包含上游驱动的完整源代码，也不包含任何硬件厂商的固件或安装包。所有上游代码通过下面的仓库、分支与提交号引入。

## 一、上游驱动 NvGfx / XeGfx

- 仓库：<https://github.com/watchthelight-labs/NvGfx>
- 分支：`xe`
- 基点提交：`5a19a73f36249efb99c44c3f9cb34603ef0c0eb8`（XeGfx 0.0.44）
- 许可证：PolyForm Noncommercial License 1.0.0（`LICENSE` 全文）
- Required Notice（上游 README 声明）：Copyright (c) 2026 NullMoth Systems（<https://nullmothsystems.com>）

上游 README 说明该驱动是 NullMoth Systems 的 macOS NVIDIA Metal 驱动的分支，全部驱动主体工作由 NullMoth Systems 完成。本仓库的改动都以补丁形式叠加在该提交之上，补丁文件名与基点写在各补丁开头的注释里。

插件部分的血缘使用较早的提交：

- 插件基点提交：`497d521e925bd760c8cde5bbc17d9bf96d2ee2b4`（XeGfx 0.0.35）的 `plugin/` 目录
- 该插件树后续改编为 XeMTL 驱动，并且一直没有与 0.0.44 同步；补丁 `0005` 到 `0007` 因此以 0.0.35 的插件目录为基线

## 二、NVIDIA 开放 GPU 内核模块

- 仓库：<https://github.com/NVIDIA/open-gpu-kernel-modules>
- 版本：610.57.04（r610）
- 许可证：MIT / GPL-2.0，按文件区分

本项目的内核侧 family 与 NVRM 部分由该仓库的源码编译而来（Open GPU Kernel Modules）。本仓库不重分发这些源码，只提供叠加在其上的补丁与编译说明。相关 MIT 许可文本如下：

```text
Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## 三、上游随附的第三方组件

上游 `NOTICE` 列出的第三方组件沿用其各自条款。本仓库不包含这些组件的源码或二进制，这里列出它们与上游的血缘关系：

- `translator/`：改编自 metal2vulkan，作者 Anees Iqbal，<https://github.com/steelbrain/metal2vulkan>，GNU Lesser General Public License v3.0 或更高版本
- `NVK`：来自 Mesa 的 Vulkan 驱动（MIT），上游的改动以补丁形式随其发布
- `GSP firmware`：按 NVIDIA 的固件许可分发，上游未修改

## 四、Apple 系统组件

- 本仓库不分发 macOS SDK 头文件、Apple 内核符号或系统 kext
- 补丁涉及 `IOKit`、`IOFramebuffer`、`CoreDisplay` 等 Apple 私有或公开接口，使用方式以本机 macOS 26.7.1（25G241）自带的 SDK 为准
- 面板 EDID 数据（补丁 `0004` 的 `xe/Info.plist`）来自本机内置屏 BOE NE160QDM-NZL，序列号字段已置零，只作为面板 timing 校验的输入

## 五、本仓库自身的许可

本仓库按内容分成两部分：

- `patches/`：对上游 NvGfx 源码的修改，属于上游工作的衍生部分，必须沿用上游的 PolyForm Noncommercial License 1.0.0，全文见 `LICENSE`。该许可把使用范围限定在非商业用途；商业使用需要另行取得授权。上游 README 明确写明「source-available, not open source」，这一限制不能由本仓库单方面放宽。
- `scripts/`、`docs/`、`README.md`、`NOTICE.md` 等由本项目原创的内容：以 MIT 许可发布，全文见 `LICENSE-MIT`。这部分可以自由使用、修改和再分发，保留版权声明即可。

拼装或再分发本仓库时，请分别遵守这两份许可：改动上游代码的部分保留 PolyForm Noncommercial 1.0.0，只使用原创脚本与文档的部分按 MIT 处理。
