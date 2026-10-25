# Metal 插件：XeMTL 血缘与 first-loss journal

## 插件在栈里的位置

桌面合成走 Metal，Metal 由 XeMTL 插件翻译成 Vulkan，Vulkan 的 Intel 驱动（ANV）再向下调用 core kext 的 ioctl 与 userptr 通路。插件是这个栈里唯一运行在用户态的组件，替换一次插件不需要重启内核；内核侧提供 userptr、显存与显示引擎，插件负责把 Metal 资源映射到 Vulkan 对象。

## 血缘：0.0.35 插件树的持续演进

XeMTL 插件由 NvGfx 0.0.35 的 `plugin/` 目录改编而来。改编的内容集中在三类：类名与符号前缀由 `NVMTL` 换成 `XeMTL`，`NVMTLDevice` 换成 `XeMTLDevice`；bundle 与环境路径由 `/Library/GPUBundles/nvmtl` 换成 `/Library/GPUBundles/xemtl`；厂商与设备标识换成 Intel Xe 的取值。XR 像素格式在这样的改编里被映射到对应的 Vulkan 格式。补丁 `0005` 记录了这次改编，改动行里绝大多数是机械重命名。

这条插件线没有跟随 0.0.44 的插件变化，因此补丁 `0006` 与 `0007` 以 0.0.35 的插件树为基线。0.0.44 对应的插件变化没有进入这条线，其中与本项目相关的修正是两个：host pointer 导入前的可写性判定（上游提交 `e60f462`，见 `device-lost.md`）与上游的日志改动。前者由补丁 `0006` 回移，后者按需保留；其余 0.0.44 插件差异不进入这条线。

## 结构：插件如何看到一次失败

Vulkan 的提交是一次性的。一次 `vkQueueSubmit` 失败之后，ANV 可能把设备标记为丢失，插件随后拿到的所有调用都会失败；第一次失败的信息窗口很短。first-loss journal 把这段窗口里的关键事件按顺序写成 JSON 行，落在一个有界文件里。

journal 的开关是显式的。插件启动时检查环境变量 `XEMTL_FIRST_LOSS_TRACE`；`1` 表示打开，`0` 表示强制关闭。对 WindowServer 这类由 launchd 启动的进程，环境变量无法从外部注入，因此另有一个 sentinel 机制：以 root 创建文件

```text
/private/tmp/xemtl-first-loss-enable
```

插件在初始化与每次事件写入前检查该文件是否存在，存在即打开 journal。同一个 sentinel 还会在进程内设置 `XEMTL_DRM_TRACE=1`，让 libdrm 层的 ioctl trace 同步打开，于是 Vulkan 提交与内核 ioctl 两侧的记录可以对齐。

journal 的落盘路径由 `XEMTL_FIRST_LOSS_DIR` 控制，默认目录是 `/private/tmp`，文件名是 `xemtl-first-loss-<pid>.jsonl`。文件以独占创建方式打开（`O_EXCL | O_NOFOLLOW | O_CLOEXEC`，权限 `0600`），避免多个进程写到同一个文件，也避免符号链接被利用。

## 记录内容

journal 把一个事件写成一行 JSON，字段覆盖事件名、pid、tick、实例、提交编号、命令缓冲、fence、队列、调用结果与时间跨度。事件集合覆盖了失败前后最需要区分的几步：

- `queue_submit_begin` / `queue_submit_end`：提交进入与返回
- `post_loss_status_query`、`fence_wait_begin` / `fence_wait_end`：失败后探活与等待
- `host_pointer_import`、`submit_skipped_backend_down`、`submit_invalid_command_buffer`：导入与提交被拒绝的原因
- `iosurface_image_binding`、`surface_host_effective`、`texture_upload_recorded`：surface 与图像绑定的上下文
- `backend_downed`：后端被标记为丢失的那一刻，只写一次
- `vulkan_driver_error` / `vulkan_driver_warning`：保留槽位，用于承接 Vulkan 驱动本身返回的错误文本

文件容量有界：常规行 2,048 行，另有 32 行保留给后端丢失后的关键事件；写满之后插件停止记录，避免长跑时把磁盘写满。journal 不参与重试、不回收资源、不改变插件行为，它的唯一职责是把第一次失败的信息留下来。

## 使用方式

一次典型的使用顺序是：

```sh
sudo touch /private/tmp/xemtl-first-loss-enable
# 重启 WindowServer 或整机，让插件带上 sentinel 启动
# 复现问题后读取 journal
ls /private/tmp/xemtl-first-loss-*.jsonl
sudo rm /private/tmp/xemtl-first-loss-enable
```

读取 journal 时先看 `backend_downed` 与 `vulkan_driver_error`，再沿它前面最近的 `queue_submit_*`、`host_pointer_import` 与 `iosurface_image_binding` 事件回溯上下文。本项目里 device lost 问题的判定链就是从 `host_pointer_import` 事件与 ANV 的 `VK_ERROR_DEVICE_LOST` 记录对上的。

## 与补丁系列的关系

插件补丁按阶段拆分，便于单独审阅：`0005` 是改编，`0006` 是导入判定，`0007` 是 journal 与配套的 syslog 记录。三者按顺序应用才能得到项目里实际参与构建的插件树；构建与安装步骤见 `building.md`。
