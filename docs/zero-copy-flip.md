# 零拷贝显示提交（GGTT 槽 flip）

这份笔记记录零拷贝 flip 的来由、边界与回退办法，配合 `patches/0008` 与 `patches/0009` 阅读。

## 为什么要做

2026-10-26 的显示接管方案把合成器交来的帧用 CPU 复制进引导固件 framebuffer（每帧 2560×1600×4 = 16,000 KB 左右，实测平均 1.3–2.0 ms，偶发峰值 19–60 ms）。复制本身还能接受，但峰值会跨过 vblank，于是出现撕裂；同时 16 MB/帧的写回也把 WindowServer 的合成路径拖慢。

这一层里真正可用的硬件事实是：

- 平面寄存器直接可写：`PLANE_SURF_1_A = 0x7019c`（pipe A 基址 0 = BAR0 偏移），写入的是 **GGTT 偏移**，不是物理地址；平面在下一个 vblank 自动生效。
- 合成器交来的每一帧是系统内存里的 IOSurface，物理页可以通过 `IOMemoryDescriptor::getPhysicalSegment` 拿到。
- XeGfx core 里的 i915 已经拥有一张真实的全局 GGTT（`i915_gem_gtt_insert` / `ggtt->vm.insert_page` / `ggtt->invalidate`）。

所以只要把帧的物理页临时挂进 GGTT 的一个槽，再写一次 `PLANE_SURF_1_A`，显示引擎就能直接扫描这块系统内存，CPU 完全不参与搬运。

## 结构

```
WindowServer 合成完成后的 IOSurface（系统内存，物理页已知）
        │
        ▼
XeGfxAccel 显示事务（debug.xegfxaccel_iop_xe_flip=1）
        │  xgFlipMap(slot, phys[], npages)   ← XeGfxResident 的 callPlatformFunction 桥
        ▼
XeGfx core：i915 GGTT 槽（xg_i915_flip.c）
        │  i915_gem_gtt_insert 预留 / insert_page + invalidate 改写 PTE
        ▼
XeGfxAccel 写 PLANE_SURF_1_A = slot 的 GGTT 偏移
        │
        ▼
显示引擎在下一个 vblank 扫描该槽（零拷贝）
```

要点：

- 槽在 `xgFlipInit` 时一次性预留（3 个，各 16,384,000 B，i915 里用 `I915_COLOR_UNEVICTABLE` 标记，位置由 i915 选，首次试验落在 `0x80000000`）。槽永不释放，`xgFlipUnmap` 只是把 PTE 指回 scratch 页，避免旧帧被扫描。
- 显示事务按「映射新帧 → 写 PLANE_SURF → 记住当帧与前两帧」推进；只有当某次 flip 证明旧槽已不在扫描中时，旧槽才会被回收复用。这样不需要读 `PLANE_SURFLIVE` 轮询也不会把正在扫描的帧改掉。
- 任意一步失败（物理页取不到、GGTT 映射失败、RPC 报错）都退回 CPU 拷贝路径，绝不会把未映射的地址写进平面寄存器。
- `debug.xegfxaccel_iop_xe_flip=0` 可以在运行时立刻关掉 flip，回到已长期验证的拷贝路径，不需要重启。

## 计数与验证

- `debug.xegfxaccel_pipe_perform`：显示事务总数（两条路径共用）。
- `debug.xegfxaccel_iop_ok`：CPU 拷贝路径的成交数。零拷贝生效时它保持 0。
- `debug.xegfxaccel_iop_xe_flip_miss/_fail`：flip 未命中（帧几何不匹配）与失败（走回退）。
- 首次验收（2026-10-26，boot 96ECC49F 之后的第二轮）：200 秒内 `pipe_perform = 2837`、`iop_ok = 0`、`flip_miss = flip_fail = 0`，无 panic、无 DEVICE_LOST；桌面 30 多分钟稳定，未再出现撕裂。之前的 A/B 诊断确认「每帧同步等合成完成」不是瓶颈，瓶颈在 WindowServer 的 CA→Metal 编码翻译路径，因此这次没有动等待逻辑。

## 风险与回退

- GGTT 槽是长期占用的：换来的是每帧免拷贝，代价是 48 MB 地址空间（不是内存）。
- 帧的生命周期依靠 accel 持有的 `IOMemoryDescriptor` 引用；IOSurface 被复用时由新的映射替换。
- WindowServer 重启后槽与状态重新初始化，无需清理。
- 立即回退：`sysctl debug.xegfxaccel_iop_xe_flip=0`。
- 下一步：硬件光标可以复用同一套 GGTT 槽；多槽轮转与 vblank 精确同步也在同一机制上扩展。
