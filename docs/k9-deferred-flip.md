# K9 延迟 flip：把 WindowServer 从 `commitAndWaitUntilSubmitted` 里解放出来

这份笔记记录 2026-10-27 恢复到 60fps 加速桌面的那条路径，配合 `patches/0007`、`patches/0008`、
`patches/0009` 与 `scripts/run_upstream_trial5.sh`、`scripts/resume-bringup.sh` 阅读。

## 问题

零拷贝 flip 打通、vblank 同步生效之后，桌面仍然只有 ~15fps（窗口基准 19.1fps）。采样显示瓶颈不在复制，
而在等待：WindowServer 的显示线程每帧在 `commitAndWaitUntilSubmitted` 里同步等 GPU 完成，实测 7.5–12.8 ms/帧。

先试过“不等”：给插件加 no-wait 提交分支后跑到 28.4fps（+48%），但出现半路呈现、撕裂、光标回退、
输入法候选框异常。这说明帧的顺序和完成时刻本身被硬件依赖，单纯让 CPU 不等并不能解决问题——需要
**内核侧排序**：WindowServer 立即返回，由驱动在“上一帧真正写完”之后再让平面扫描新帧。

## 机制

1. **core 侧空闲探测**（`0008`）：`xg_i915_idle()` 遍历各 uabi engine 的 `intel_engine_is_idle()`，返回
   `1` 空闲 / `0` 忙 / `-ENODEV` 无 i915 设备，不睡眠、可在 thread context 调用；通过 `XeGfxResident` 的
   `callPlatformFunction` 桥以 `"xgFlipQuery"` 暴露。
2. **加速器侧 defer worker**（`0009`）：帧的物理页映射进 GGTT 槽后**不**立即写 `PLANE_SURF_1_A`；worker
   轮询 `xgFlipQuery`，空闲后才 arm 平面。`debug.xegfxaccel_iop_xe_defer=1` 打开，
   `iop_xe_report_busy` / `iop_xe_wait_idle` / `iop_xe_idle_ms` 调节等待与上报，
   `defer_armed` / `defer_signals` / `wait_max_us` 计数。
3. **插件 no-wait 提交 + census 计数**（`0007`）：提交路径不再同步等 fence，逐调用记录耗时与首损事件，
   供诊断和 K9b 参数选择。
4. **framebuffer detailed timings**（`0010`）与 AGDC K5 链路（`0004`）保持不变——平面能在 vblank 精确
   生效依赖它们。

## 启用（bring-up 完成、heads 16/16/16 之后，root）

```sh
sysctl -w debug.xegfxaccel_iop_xe_defer=1
sysctl -w debug.xegfxaccel_iop_xe_report_busy=1
sysctl -w debug.xegfxaccel_iop_xe_wait_idle=1
sysctl -w debug.xegfxaccel_iop_xe_idle_ms=40
touch /private/tmp/xemtl-ws-nowait
```

`xemtl-ws-nowait` 哨兵让（重新启动后的）WindowServer 里的插件走 no-wait 提交分支。

## 结果（2026-10-27，2560×1600@60Hz，无开机自启）

- 同步等待 ~15fps → 延迟 flip ~60fps；`defer_armed` / `defer_signals` 每帧递增，
  `surface_gpu_on=1`，窗口拖动/滚动/光标正常且无撕裂。
- 完整恢复流程（门控 core 开机**不**加载，符合“不要启动时自动加载”的要求）：
  1. 正常开机（未加速桌面，L0 framebuffer 由固件点亮）；
  2. 手动 bring-up：`scripts/run_upstream_trial5.sh`（加载 core → 加速器 → head-4 注册 → 单次 WindowServer
     重启），`scripts/resume-bringup.sh` 把这一步与 K9b 参数一起封装；
  3. 重新登录，桌面即为加速 + 延迟 flip 状态。

## 注意

- head-4 注册不完整（`heads_registered` / `heads_piped` 不是 16）时 `run_upstream_trial5.sh` 不会重启
  WindowServer，避免把无加速会话踢掉。
- 回退：`iop_xe_defer=0` 回到同步 flip；`iop_xe_flip=0` 回到 CPU 拷贝扫描路径。
