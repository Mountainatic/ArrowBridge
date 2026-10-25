# Vulkan device lost：只读 host pointer 被当成可写 userptr

## 现象

加速桌面运行一段时间后，WindowServer 的 Vulkan 设备会丢失（`VK_ERROR_DEVICE_LOST`）。表现是 Metal 提交突然失败，桌面进入降级状态。同类现象在 journal 里留下一个固定的触发序列：一次 host pointer 导入、随后一次 draw 提交、Vulkan 驱动返回错误、设备丢失。

## 机制：i915 userptr 的写语义

插件里有一条 host pointer 导入路径。WindowServer 传入一块由它自己管理的宿主内存时，插件可以选择把它注册成 i915 userptr，让 GPU 直接读写这块内存，从而省掉一次复制。i915 在 pin userptr 时按“会被写入”处理，调用 `get_user_pages` 时带 `FOLL_WRITE`，要求映射具备写权限。

触发问题的对象是一块 16 MB 的只读 host pointer。它来自 WindowServer 的只读映射；当插件把它当成可写 userptr 导入时，pin 在 `FOLL_WRITE` 上失败并返回 `EFAULT`。引用该缓冲的 draw 提交在 ANV 里随之失败，Vulkan 设备被标记为丢失，桌面失去 GPU 加速。

## 结构：导入前的可写性判定

修复放在导入路径的入口。函数 `nvmtl_range_writable(ptr, size)` 遍历指针背后的 VM region，逐个检查映射的 `protection` 是否包含 `VM_PROT_WRITE`；任何一个 region 起点不齐或者缺少写权限，就判定整段不可导入。判定通过才走 userptr 导入，否则导入函数返回失败，调用方改走复制路径，把数据复制到由驱动分配的显存后再提交。

这个判定是上游 NvGfx 提交 `e60f462` 的内容。本项目的插件树停在 0.0.35，没有带上该提交，因此补丁 `0006` 把它回移到这条插件线上。代码里保留了判定失败时的日志：

```c
nvlog("vk: host-pointer import refused — %p (+%zu) is not all writable memory; that buffer is COPIED", ptr, size);
```

日志有次数上限，避免只读缓冲每帧导入时刷屏。退回复制路径之后，这块 16 MB 缓冲每次上屏多出一次复制，代价计入 `performance.md` 的帧成本。

## 证据与复现

判定逻辑本身可以用一个最小复现验证：把一段匿名内存映射成只读，作为 host pointer 交给 i915 的 userptr pin，观察返回值落在 `EFAULT`（errno 14）；随后改用带 `I915_USERPTR_READ_ONLY` 标志的路径，pin 成功。这个复现只在本机运行过，程序没有放进仓库，它确认了失败点落在 pin 的写权限检查上。

打开 first-loss journal 之后，`host_pointer_import` 事件会记录每次导入的判定结果与后续动作。该 journal 的开启方式与字段见 `plugin.md`。设备丢失问题修复后的试验里，桌面上屏计数器继续增长，WindowServer 没有再出现同一条丢失序列。

## 与另一条 userptr 问题的关系

这里处理的是导入阶段的写权限判定；同一套 userptr 机制在页面回收阶段还有另一个问题，表现为内核 panic。那条问题由 `xg_vm.c` 的修复解决，分析见 `userptr-panic.md`。
