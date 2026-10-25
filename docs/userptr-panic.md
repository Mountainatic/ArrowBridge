# userptr 拆除竞态：在内核里触发的一次页释放 panic

## 现象与现场

加速桌面连续使用一段时间之后，内核会 panic。panic 文本的第一行固定为：

```text
panic(cpu N): xegfx: vm: freeing wired page 0x... (ref 0x1)
```

调用栈从工作队列一路走到 shim 的页释放函数：

```text
xg_bsd_vm_page_free <- linux_release_pages <- i915_gem_userptr_put_pages
  <- __i915_gem_object_pages_fini <- __i915_gem_free_objects
  <- linux_work_fn <- xg_tq_worker
```

这条栈指向 i915 userptr 对象的“解除 pin、释放页”路径。触发频率与图形负载相关：加速桌面正常使用大约 20 分钟后出现一次，负载越密集出现越快。

## 结构：一页 userptr 页的三种身份

理解竞态需要先看清一页 userptr 内存在这套 shim 里的三重身份。

第一重是进程页。WindowServer 或 Metal 客户端把用户页交给 i915，pin 的动作由 `vm_fault_quick_hold_pages` 完成；成功后，页的 wiring 计数增加一。第二重是 shim 的页记录。shim 用 trie 管理已 pin 的地址区间，userptr 页对应 `XG_RUN_USER` 类型的 run。第三重是 LinuxKPI 的对象生命周期。i915 在对象析构时调用 `put_page`，LinuxKPI 把它翻译成 `vm_page_unwire` 或 `vm_page_unwire_noq`，由此减少 wiring 计数。

加速桌面把这三重身份叠在一起：ANV 会把同一个 IOSurface 通过多个 userptr 对象同时导入，WindowServer 与客户端又各自持有引用。因此同一页可能被多个对象 pin 住，wiring 计数大于一，最后一个引用离开时才需要真正释放。

## 竞态：pin 与最后一次 unwire 分处两个临界区

旧实现里，pin 与 unwire 各自加锁，临界区互不覆盖。这样会留下一个窗口：最后一个 unwire 在当前临界区内减到 0，判定“该页可以释放”；在锁外准备 kfree 的这段时间里，另一个线程 pin 到同一页并把 wiring 计数加回 1。释放动作随后发生，页带着新的引用计数进入空闲链表。之后某次访问就会撞上 panic 文本里的 `ref 0x1` 形态：页已经被回收，却还带着一个 wiring。

问题有两个可修的落点。一个是在 pin 侧拒绝复用正在被释放的页，另一个是让“减到零、退掉 run、释放页”在同一个临界区内完成。项目选择后者：修正在结构上消除了中间状态，也顺便定义了页记录与 wiring 计数之间的不变式。

## 修正：私有 oflags 标记与单一 unwire 路径

补丁 `0001` 的实现由四个部分组成，它们围绕同一个不变式展开：`XG_RUN_USER` 的 run 只要还在 trie 里，就至少持有一个 wiring。

1. **标记位**。shim 用 `oflags` 的私有位 `XG_VPO_USERHOLD (0x40)` 标记“这页属于 userptr run”。`oflags` 的标准 `VPO_*` 位占 `0x01` 到 `0x08`，`0x40` 在 shim 里未被占用。
2. **统一的 unwire 入口**。新函数 `xg_vm_user_unwire()` 在 `xg_vm_mtx` 内完成三件事：在 trie 里查找 run、执行 `vm_page_drop()`、在计数归零时把 run 从 trie 摘下并交给锁外释放。`vm_page_unwire()` 与 `vm_page_unwire_noq()` 在减少计数之前先调用它；命中 userptr 页时直接返回，不再走原来的快速路径。
3. **释放保护**。`vm_page_free()` 在入口检查 `XG_VPO_USERHOLD`，命中的页直接返回并打印限次日志。这样即使有代码绕过 unwire 路径，user-held 页也不会被交给空闲链表。
4. **pin 侧建 run**。`vm_fault_quick_hold_pages` 在 pin 时通过 `xg_vm_user_page_hold()` 建立或复用 run，并在新建 run 的第一个页上设置标记位。run 的插入与复用都在 `xg_vm_mtx` 内完成，插入失败时回退引用计数后重试。

由此得到两条可以直接检查的性质。第一，pin 要么找到已有 run 并把它的引用加一，要么在没有 run 时新建一个；任何时刻都没有“run 在 trie 里但 wiring 为零”的状态。第二，只有减到零的那次 unwire 会摘除 run 并释放页，其他线程在解锁之后不再触碰这页。panic 文本里新增的断言覆盖了这两条性质：对未接线页 pin、对未接线页 unwire、整页 run 的页数异常，都会在开发期立刻暴露出来。

## 验证：40 分钟 userptr 抖动压测

修正在一台目标机上用长时间压测验证。压测由 `scripts/soak_userptr_test.sh` 驱动：`ca_bench2` 反复起停制造窗口动画与合成器提交，`soak_surface_churn` 常驻制造 IOSurface 的创建、写入、提交与丢弃，两层负载共同覆盖 pin/unpin 的密集路径。

最近一次完整压测的结果：

- 时长 40 分 08 秒，共 37 轮，`ca_bench2` 启动 469 次
- userptr churn 迭代 527,696 次，创建/释放 IOSurface 1,583,088 个
- `panic_hit = 0`，`reboot_hit = 0`，内核日志没有新的 panic，boot 身份未变
- 压测期间桌面持续上屏，`iop_ok` 从 2,980 增长到 48,191

同一脚本在修正之前的版本上能复现 panic，修正之后连续多轮压测保持干净。补丁 `0001` 的头部注释也记录了这组数字，soak 脚本本身随仓库发布，见 `scripts/README.md`。

## 下一步

userptr 的另一条问题发生在导入阶段，由插件侧的可写性判定解决，见 `device-lost.md`。两条修复合起来之后，userptr 的 pin、unpin 与导入路径在长时间负载下保持稳定，才有条件把注意力转回显示链路的刷新率问题。
