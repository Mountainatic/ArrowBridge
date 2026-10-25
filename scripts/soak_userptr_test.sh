#!/bin/bash
# ============================================================================
# soak_userptr_test.sh —— XeGfx / NVAccel userptr 压测 + 取证（用户态，无需 root）
#
# 背景：修复版 XeGfx core kext + XeGfxAccel + XeMTL 插件安装后，需要长时间跑图形负载
# 来验证/复现内核 panic（曾经在加速桌面正常使用约 19.5 分钟后触发一次）：
#
#   panic(cpu N): xegfx: vm: freeing wired page 0x... (ref 0x1)
#   xg_bsd_vm_page_free <- linux_release_pages <- i915_gem_userptr_put_pages
#     <- __i915_gem_object_pages_fini <- __i915_gem_free_objects <- linux_work_fn
#     <- xg_tq_worker
#
# 也就是 i915 userptr 对象的"解除 pin / 释放页"路径里页引用计数不对（多减了一次），
# 触发条件是 WindowServer / Metal 客户端反复 pin 再 unpin 同一批共享用户页。
#
# 本脚本只做三件事（不加载/卸载 kext、不重启 WindowServer、不写 /Library、不用 sudo）：
#   1) 持续制造 Metal / IOAccel / IOSurface 负载：
#        - 反复起停 ca_bench2（窗口 + CABasicAnimation，驱动合成器/display pipe）
#        - 常驻 soak_surface_churn（每次迭代新建 IOSurface 写满共享页，塞进 layer.contents
#          提交给 WindowServer，然后立刻丢弃 -> 高频 alloc/pin/unpin/free）
#   2) 每 SAMPLE_SEC 秒采样一次遥测（uptime / boot 身份 / 驱动计数器 / WindowServer CPU /
#      前台 App），追加到 timeline.log
#   3) 每轮结束抓统一日志、比对 Kernel-*.panic 基线、比对 boot 身份；一旦发现新 panic 或
#      机器重启过，立刻落证据（PANIC_DETECTED / REBOOT_DETECTED）并非零退出
#
# 用法：
#   ./soak_userptr_test.sh                          # 默认 20 分钟，输出到 ni/work/soak-<stamp>
#   DURATION_MIN=45 ./soak_userptr_test.sh          # 跑 45 分钟
#   DURATION_MIN=30 OUT=/tmp/soak1 ./soak_userptr_test.sh
#   bash -x ./soak_userptr_test.sh                  # 调试
#
# 可调环境变量：
#   DURATION_MIN  总时长（分钟，默认 20）
#   OUT           输出目录（默认 $PWD/soak-<YYYYmmdd-HHMMSS>）
#   XE_NI_DIR     项目 helper 脚本目录（可选，默认 $HOME/Documents/Codex/2026-10-24/ni）
#   XE_TOOLS_DIR  负载程序源码目录（默认脚本所在目录的 tools/）
#   ROUND_SEC     每轮秒数（默认 75，建议 60-90）
#   SAMPLE_SEC    采样间隔秒（默认 10）
#   CA_EVERY      每隔多少秒再补一个 ca_bench2 实例（默认 6；ca_bench2 自身约 7s 结束）
#   CA_PROCS      每轮开始时先并行起几个 ca_bench2（默认 2）
#   CHURN_WIN     soak_surface_churn 的窗口数（默认 1）
#   CHURN_SURF    soak_surface_churn 每迭代每窗口新建的 surface 数（默认 2）
#   SOAK_METAL    1 = 让 churn 额外走 Metal 纹理绑定（默认 0；驱动不稳时再开）
#   DURATION_SEC  自检用：直接指定总秒数，覆盖 DURATION_MIN（正常压测不要设）
#
# 退出码：0 = 跑满且干净；3 = 检测到重启（疑似 panic）；4 = 检测到 panic/致命日志；
#         5 = 两个负载都跑不起来（环境问题）；130/143 = 被信号打断
# ============================================================================
set -u

# ---------------------------------------------------------------- 0. 基本参数
# Sanitised copy: NI points at the project helper directory (optional), TOOLS at this
# repository's scripts/tools directory, so the two load programs build from the shipped sources.
HERE=$(cd "$(dirname "$0")" && pwd)
NI="${XE_NI_DIR:-$HOME/Documents/Codex/2026-10-24/ni}"
TOOLS="${XE_TOOLS_DIR:-$HERE/tools}"
BENCH_SRC="$TOOLS/ca_bench2.m"
BENCH_BIN=/tmp/ca_bench2
CHURN_SRC="$TOOLS/soak_surface_churn.m"
CHURN_BIN=/tmp/soak_surface_churn
PANIC_DIR=/Library/Logs/DiagnosticReports
MARK_FILE=/tmp/soak_userptr_bootmark

as_int() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

DURATION_MIN=$(as_int "${DURATION_MIN:-}" 20)
ROUND_SEC=$(as_int "${ROUND_SEC:-}" 75)
SAMPLE_SEC=$(as_int "${SAMPLE_SEC:-}" 10)
CA_EVERY=$(as_int "${CA_EVERY:-}" 6)
CA_PROCS=$(as_int "${CA_PROCS:-}" 2)
CHURN_WIN=$(as_int "${CHURN_WIN:-}" 1)
CHURN_SURF=$(as_int "${CHURN_SURF:-}" 2)
SOAK_METAL=$(as_int "${SOAK_METAL:-}" 0)
DURATION_SEC_OVERRIDE=$(as_int "${DURATION_SEC:-}" 0)

[ "$ROUND_SEC" -ge 20 ] || ROUND_SEC=20
[ "$ROUND_SEC" -le 600 ] || ROUND_SEC=600
[ "$SAMPLE_SEC" -ge 1 ] || SAMPLE_SEC=1
[ "$CA_EVERY" -ge 2 ] || CA_EVERY=2
[ "$CA_PROCS" -ge 1 ] || CA_PROCS=1
[ "$CHURN_WIN" -ge 1 ] || CHURN_WIN=1
[ "$CHURN_SURF" -ge 1 ] || CHURN_SURF=1

if [ "$DURATION_SEC_OVERRIDE" -gt 0 ]; then
  TOTAL=$DURATION_SEC_OVERRIDE
else
  TOTAL=$((DURATION_MIN * 60))
fi
[ "$TOTAL" -ge 20 ] || TOTAL=20

STAMP=$(date '+%Y%m%d-%H%M%S')
OUT="${OUT:-$PWD/soak-$STAMP}"
LOGS="$OUT/logs"
mkdir -p "$OUT" "$LOGS" || { echo "无法创建输出目录 $OUT" >&2; exit 1; }

# 终端输出走 fd3，其余全部落 script.log（便于事后只看一个文件）
SCRIPT_LOG="$OUT/script.log"
exec 3>&1
exec >>"$SCRIPT_LOG" 2>&1

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log()     { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
say()     { printf '%s\n' "$*"; printf '%s\n' "$*" >&3; }
warn()    { log "WARN: $*"; printf 'WARN: %s\n' "$*" >&3; }
fmt_dur() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }

# 探测 sysctl 前缀：不同构建可能是 debug.xegfxaccel_ / debug.nvaccel_ / debug.nmxaccel_
PREFIXES="debug.xegfxaccel_ debug.nvaccel_ debug.nmxaccel_"
ACCEL_COUNTERS="iop_ok iop_fail iop_empty iop_src_surf iop_src_res iop_flips scanout_copies \
pipe_perform surface_gpu_on surface_gpu_waits surface_gpu_timeouts vm_alloc vm_dealloc \
vm_parked vm_unparked vm_refused res_new res_free heads_piped heads_registered heads_published iop_async"
CORE_COUNTERS="stage progress running wdog agdc agdc_k5 panel_probe"

resolve_counters() {   # 把逻辑名解析成实际存在的 sysctl 全名，存到 R_<name> / Rc_<name>
  local n p
  for n in $ACCEL_COUNTERS; do
    eval "R_$n='-'"
    for p in $PREFIXES; do
      if /usr/sbin/sysctl -n "${p}${n}" >/dev/null 2>&1; then eval "R_$n='${p}${n}'"; break; fi
    done
  done
  for n in $CORE_COUNTERS; do
    eval "Rc_$n='-'"
    if /usr/sbin/sysctl -n "debug.xegfx_${n}" >/dev/null 2>&1; then eval "Rc_$n='debug.xegfx_${n}'"; fi
  done
}

cv() {   # cv <accel 逻辑名> -> 值，缺失返回 "-"（永远不失败）
  local n="$1" f v
  case "$n" in *[!a-z0-9_]*) printf '%s' '-'; return 0 ;; esac
  eval "f=\${R_$n-}"
  if [ -z "$f" ] || [ "$f" = "-" ]; then printf '%s' '-'; return 0; fi
  if v=$(/usr/sbin/sysctl -n "$f" 2>/dev/null); then printf '%s' "$v"; else printf '%s' '-'; fi
}

cf() {   # cf <core 逻辑名>（debug.xegfx_*）
  local n="$1" f v
  case "$n" in *[!a-z0-9_]*) printf '%s' '-'; return 0 ;; esac
  eval "f=\${Rc_$n-}"
  if [ -z "$f" ] || [ "$f" = "-" ]; then printf '%s' '-'; return 0; fi
  if v=$(/usr/sbin/sysctl -n "$f" 2>/dev/null); then printf '%s' "$v"; else printf '%s' '-'; fi
}

boot_sec() {   # kern.boottime 的 epoch 秒（重启后一定变大）；拿不到返回空
  # 注意不能写 s/.*sec = //：kern.boottime 里还有 "usec = ..."，贪婪匹配会取到微秒字段
  /usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/awk '{
    for (i = 1; i <= NF; i++) if ($i == "sec" && $(i+1) == "=") { print $(i+2); exit }
  }' | /usr/bin/tr -d ','
}

boot_id() {    # boot 身份三元组，用于判定"是否换了一次开机"
  local s uuid sess
  s=$(boot_sec); s=${s:-0}
  uuid=$(/usr/sbin/sysctl -n kern.bootuuid 2>/dev/null || true)
  sess=$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)
  printf 'bootsec=%s bootuuid=%s session=%s' "$s" "${uuid:--}" "${sess:--}"
}

ws_pid() { /usr/bin/pgrep -x WindowServer 2>/dev/null | /usr/bin/head -1; }

front_app() {  # 当前前台 App 名字（一行，失败则退化为 lsappinfo list 第一行）
  local asn n
  asn=$(/usr/bin/lsappinfo front 2>/dev/null || true)
  if [ -n "$asn" ]; then
    n=$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null | /usr/bin/sed 's/.*=//; s/"//g' | /usr/bin/head -1)
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  fi
  /usr/bin/lsappinfo list 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -c1-60 | /usr/bin/tr ' ' '_'
}

kext_lines() { /usr/sbin/kextstat 2>/dev/null | /usr/bin/grep -Ei 'xegfx|nvaccel|nvmtl|xemtl' || true; }

panic_list() { /bin/ls -1 "$PANIC_DIR"/Kernel-*.panic 2>/dev/null | LC_ALL=C /usr/bin/sort; }

# ================================================================ 1. 启动前状态
RUN_START_EPOCH=$(date +%s)
BOOT_SEC_0=$(boot_sec); BOOT_SEC_0=${BOOT_SEC_0:-0}
BOOT_UUID=$(/usr/sbin/sysctl -n kern.bootuuid 2>/dev/null || true)
BOOT_SESSION=$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)
WS_PID=$(ws_pid)
resolve_counters

log "=== soak_userptr_test start $(ts) pid=$$ out=$OUT"
log "TOTAL=${TOTAL}s round=${ROUND_SEC}s sample=${SAMPLE_SEC}s ca_procs=$CA_PROCS churn_win=$CHURN_WIN churn_surf=$CHURN_SURF metal=$SOAK_METAL"

say ""
say "== XeGfx userptr soak ==================================================="
say " 输出目录 : $OUT"
say " 计划时长 : $(fmt_dur "$TOTAL")  每轮 ${ROUND_SEC}s  采样 ${SAMPLE_SEC}s"
say " boot     : $(boot_id)"
say " WindowServer pid : ${WS_PID:-none}"
say " 中断     : Ctrl-C 会清理负载并打印 SUMMARY"
say "========================================================================="
say ""

# 1.1 基线：panic 文件列表 + 完整 sysctl 快照 + 加载的 kext
panic_list > "$OUT/panics.before.txt"
: > "$OUT/panics.seen.txt"
panic_list >> "$OUT/panics.seen.txt"
/usr/sbin/sysctl -a 2>/dev/null | /usr/bin/grep -E '^debug\.(xegfx|nvaccel|nmxaccel)' \
  > "$OUT/sysctl-at-start.txt" || true
kext_lines > "$OUT/kexts-at-start.txt" || true

# 1.2 上一轮（可能是 panic 重启前）留下的 bootmark：判断"上次 soak 后是否重启过/是否 panic"
prev_get() { [ -r "$MARK_FILE" ] || return 0; /usr/bin/grep "^$1=" "$MARK_FILE" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d= -f2-; }
PREV_SESSION=$(prev_get bootsession)
PREV_EPOCH=$(prev_get epoch)
PREV_OUT=$(prev_get out)
PREV_STAMP=$(prev_get stamp)
PREV_RESTARTED=no
PREV_PANIC_SUSPECT=no
PREV_PANIC_FILE=""
if [ -n "$PREV_SESSION" ] && [ -n "${BOOT_SESSION:-}" ] && [ "$PREV_SESSION" != "$BOOT_SESSION" ]; then
  PREV_RESTARTED=yes
  NEWEST_PANIC=$(/bin/ls -1t "$PANIC_DIR"/Kernel-*.panic 2>/dev/null | /usr/bin/head -1)
  if [ -n "$NEWEST_PANIC" ] && [ -n "$PREV_EPOCH" ]; then
    M=$(/usr/bin/stat -f %m "$NEWEST_PANIC" 2>/dev/null || echo 0)
    if [ "${M:-0}" -ge "$PREV_EPOCH" ] 2>/dev/null; then
      PREV_PANIC_SUSPECT=yes
      PREV_PANIC_FILE="$NEWEST_PANIC"
      /bin/mkdir -p "$OUT/prev-panic" 2>/dev/null || true
      /bin/cp -p "$NEWEST_PANIC" "$OUT/prev-panic/" 2>/dev/null || true
      {
        echo "ts=$(ts)"
        echo "previous_soak_stamp=$PREV_STAMP"
        echo "previous_out=$PREV_OUT"
        echo "previous_bootsession=$PREV_SESSION"
        echo "now_bootsession=${BOOT_SESSION:-unknown}"
        echo "panic_file=$NEWEST_PANIC"
        echo "panic_mtime=$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$NEWEST_PANIC" 2>/dev/null)"
        echo "note=上一次 soak 跑完之后系统重启过，并且有新的 Kernel panic 文件；很可能是该轮压测打出的 panic"
      } > "$OUT/PREVIOUS_RUN_PANIC_SUSPECT"
      warn "上次 soak（${PREV_STAMP}，${PREV_OUT}）之后重启过，且出现新 panic：$NEWEST_PANIC"
      warn "详情见 $OUT/PREVIOUS_RUN_PANIC_SUSPECT"
    fi
  fi
  if [ "$PREV_PANIC_SUSPECT" = "no" ]; then
    { echo "ts=$(ts)"; echo "previous_soak_stamp=$PREV_STAMP"; echo "previous_out=$PREV_OUT";
      echo "previous_bootsession=$PREV_SESSION"; echo "now_bootsession=${BOOT_SESSION:-unknown}";
      echo "note=上次 soak 之后重启过，但没有比它更新的 Kernel panic 文件（可能是正常重启或别的原因）"; } \
      > "$OUT/PREVIOUS_RUN_RESTARTED"
  fi
fi

# 1.3 预检：会话/负载工具/加速器是否在线（只告警，不退出）
pre_issues=""
[ -n "$WS_PID" ] || pre_issues="$pre_issues no-WindowServer"
[ -x /usr/bin/clang ] || pre_issues="$pre_issues no-clang"
[ -x /usr/bin/perl ] || pre_issues="$pre_issues no-perl"
[ -f "$BENCH_SRC" ] || pre_issues="$pre_issues missing-ca_bench2.m"
[ -f "$CHURN_SRC" ] || pre_issues="$pre_issues missing-soak_surface_churn.m"
HP=$(cv heads_piped)
HL=""   # headless 标志：前缀随构建而变，逐个探测哪个存在
for _p in $PREFIXES; do
  if HL=$(/usr/sbin/sysctl -n "${_p}headless" 2>/dev/null); then break; fi
  HL=""
done
if [ "$(cv iop_ok)" = "-" ] && [ "$(cf stage)" = "-" ]; then
  pre_issues="$pre_issues no-accel-sysctl"
fi
case "$HP" in 0|'-') pre_issues="$pre_issues heads_piped=$HP" ;; esac
[ "${HL:-0}" = "1" ] && pre_issues="$pre_issues accel-headless=1"
pre_issues=${pre_issues# }
[ -n "$pre_issues" ] && pre_issues="${pre_issues// /,}"

# 1.4 before.txt：把启动状态一次性写全
{
  echo "# soak_userptr_test before-state"
  echo "ts=$(ts)"
  echo "host=$(/bin/hostname)"
  echo "user=$(/usr/bin/id -un) uid=$(/usr/bin/id -u)"
  echo "os=$(/usr/bin/sw_vers -productVersion 2>/dev/null) build=$(/usr/bin/sw_vers -buildVersion 2>/dev/null)"
  echo "kernel=$(/usr/bin/uname -r) arch=$(/usr/bin/uname -m)"
  echo "boot_identity: $(boot_id)"
  echo "boottime=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null)"
  echo "uptime_sec=$(( RUN_START_EPOCH - BOOT_SEC_0 ))"
  echo "uptime_human=$(fmt_dur $(( RUN_START_EPOCH - BOOT_SEC_0 )))"
  echo "WindowServer_pid=${WS_PID:-none}"
  echo "front_app=$(front_app)"
  echo "console_user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)"
  echo "precheck=${pre_issues:-ok}"
  echo
  echo "[loaded kexts: xegfx/nvaccel/nvmtl]"
  kext_lines
  echo
  echo "[resolved sysctl names]"
  for n in $ACCEL_COUNTERS; do eval "f=\${R_$n-}"; printf '  %-20s -> %s\n' "$n" "${f:--}"; done
  for n in $CORE_COUNTERS; do eval "f=\${Rc_$n-}"; printf '  %-20s -> %s\n' "$n" "${f:--}"; done
  echo
  echo "[counter values at start]"
  for n in $ACCEL_COUNTERS; do printf '  %-20s %s\n' "$n" "$(cv "$n")"; done
  for n in $CORE_COUNTERS; do printf '  %-20s %s\n' "$n" "$(cf "$n")"; done
  echo
  echo "[panic baseline] ($(panic_list | /usr/bin/wc -l | /usr/bin/tr -d ' ') files)"
  panic_list | /usr/bin/sed 's/^/  /'
  echo
  echo "[previous soak mark]"
  if [ -r "$MARK_FILE" ]; then /usr/bin/sed 's/^/  /' "$MARK_FILE"; else echo "  (none)"; fi
  echo "  previous_restarted=$PREV_RESTARTED previous_panic_suspect=$PREV_PANIC_SUSPECT"
} > "$OUT/before.txt"

# 1.5 写本轮 bootmark（下次运行/重启后能对上）
{
  echo "stamp=$STAMP"
  echo "epoch=$RUN_START_EPOCH"
  echo "bootsession=${BOOT_SESSION:-unknown}"
  echo "bootuuid=${BOOT_UUID:-unknown}"
  echo "bootsec=$BOOT_SEC_0"
  echo "out=$OUT"
} > "$MARK_FILE" 2>/dev/null || warn "无法写 ${MARK_FILE}（不影响本次压测）"
/bin/chmod 600 "$MARK_FILE" 2>/dev/null || true

[ -n "$pre_issues" ] && warn "预检告警：${pre_issues}（压测继续，但结果可能无意义）"

# ================================================================ 2. 工具函数
LOAD_PIDS=""
LOAD_PID=""
SAMPLER_PID=""
STOP_FILE="$OUT/.stop"
# OUT 若被复用，上一轮残留的 .stop / .round 会让本次立刻退出，先清掉
if [ -f "$STOP_FILE" ]; then
  /bin/rm -f "$STOP_FILE"
  log "清理上次残留的 .stop（OUT 目录被复用）"
fi
printf '0\n' > "$OUT/.round"
PANIC_HIT=0
REBOOT_HIT=0

reap_loads() {
  local keep="" p
  for p in $LOAD_PIDS; do
    if /bin/kill -0 "$p" 2>/dev/null; then keep="$keep $p"; else /usr/bin/wait "$p" 2>/dev/null || true; fi
  done
  LOAD_PIDS="${keep# }"
}

kill_loads() {
  local p i
  [ -z "${LOAD_PIDS:-}" ] && return 0
  for p in $LOAD_PIDS; do /bin/kill -TERM "$p" 2>/dev/null || true; done
  i=0; while [ "$i" -lt 5 ]; do sleep 0.2; i=$((i+1)); done
  for p in $LOAD_PIDS; do /bin/kill -KILL "$p" 2>/dev/null || true; done
  for p in $LOAD_PIDS; do /usr/bin/wait "$p" 2>/dev/null || true; done
  LOAD_PIDS=""
}

# 用 perl 的 alarm 做超时包装（macOS 没有 timeout(1)）：
# alarm 到点后 SIGALRM 直接打在 exec 出来的进程上；返回的 pid 就是负载本身，kill 得掉。
# 注意：这里的 pid 必须写回当前 shell 的全局变量（不能用 $(...) 捕获，
# 否则函数在子 shell 里执行，LOAD_PIDS 的追加会丢失，kill_loads 就管不到它们）。
launch_load() {  # launch_load <logfile> <max_secs> <cmd...> -> 结果放 LOAD_PID
  local logf="$1" secs="$2"
  LOAD_PID=""
  shift 2
  [ -x "$(command -v "$1" 2>/dev/null || true)" ] || { log "跳过不存在的负载：$1"; return 0; }
  if [ -x /usr/bin/perl ]; then
    /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127;' "$secs" "$@" >>"$logf" 2>&1 &
  else
    "$@" >>"$logf" 2>&1 &
  fi
  LOAD_PID=$!
  LOAD_PIDS="$LOAD_PIDS $LOAD_PID"
}

ensure_bins() {   # 源码比二进制新、或二进制不存在时编译（不碰 tools/ 里的源码）
  if [ -f "$BENCH_SRC" ] && { [ ! -x "$BENCH_BIN" ] || [ "$BENCH_SRC" -nt "$BENCH_BIN" ]; }; then
    log "编译 ca_bench2 -> $BENCH_BIN"
    /usr/bin/clang -O2 -framework Cocoa -framework QuartzCore -o "$BENCH_BIN" "$BENCH_SRC" \
      >>"$OUT/compile.log" 2>&1 || log "ca_bench2 编译失败（见 compile.log）"
  fi
  if [ -f "$CHURN_SRC" ] && { [ ! -x "$CHURN_BIN" ] || [ "$CHURN_SRC" -nt "$CHURN_BIN" ]; }; then
    log "编译 soak_surface_churn -> $CHURN_BIN"
    /usr/bin/clang -O2 -framework Cocoa -framework QuartzCore -framework IOSurface \
      -framework Metal -framework CoreVideo -o "$CHURN_BIN" "$CHURN_SRC" \
      >>"$OUT/compile.log" 2>&1 || log "soak_surface_churn 编译失败（见 compile.log）"
  fi
  [ -x "$BENCH_BIN" ] || warn "缺少 ${BENCH_BIN}：CA 动画负载不可用"
  [ -x "$CHURN_BIN" ] || warn "缺少 ${CHURN_BIN}：IOSurface 抖动负载不可用"
}

mark_degraded() { printf '%s\n' "$*" >> "$OUT/DEGRADED"; }

# ================================================================ 3. panic / reboot 取证
check_new_panics() {   # check_new_panics <tag>
  local tag="$1" p sz mt hit
  for p in $(panic_list); do
    /usr/bin/grep -Fxq "$p" "$OUT/panics.seen.txt" 2>/dev/null && continue
    printf '%s\n' "$p" >> "$OUT/panics.seen.txt"
    sz=$(/usr/bin/stat -f %z "$p" 2>/dev/null || echo '?')
    mt=$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$p" 2>/dev/null || echo '?')
    hit=$(/usr/bin/grep -o 'xegfx: vm: freeing wired page[^"\\]*' "$p" 2>/dev/null | /usr/bin/head -1)
    {
      echo "ts=$(ts)"
      echo "tag=$tag"
      echo "file=$p"
      echo "size=$sz mtime=$mt"
      echo "match=${hit:-none}"
      echo "backtrace=$(/usr/bin/grep -o 'xg_bsd_vm_page_free[^"\\]*' "$p" 2>/dev/null | /usr/bin/head -1)"
    } >> "$OUT/PANIC_DETECTED"
    /bin/cp -p "$p" "$OUT/" 2>/dev/null || warn "复制 panic 文件失败（权限？）：$p"
    log "!!! 新 panic：$p (mtime=$mt) match=${hit:-none}"
    PANIC_HIT=1
    : > "$STOP_FILE"
  done
}

reboot_detected() {   # reboot_detected <reason>
  local now_s now_sec
  now_s=$(date +%s)
  now_sec=$(boot_sec); now_sec=${now_sec:-0}
  {
    echo "ts=$(ts)"
    echo "reason=$1"
    echo "start_bootsec=$BOOT_SEC_0 start_bootuuid=${BOOT_UUID:-unknown} start_session=${BOOT_SESSION:-unknown}"
    echo "now_bootsec=$now_sec now_bootuuid=$(/usr/sbin/sysctl -n kern.bootuuid 2>/dev/null || echo unknown)"
    echo "now_session=$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || echo unknown)"
    echo "uptime_now=$(( now_s - now_sec ))s"
    echo "note=uptime 变小 / boot 身份变化 = 本机在这次压测期间重启过（panic 或断电）"
  } > "$OUT/REBOOT_DETECTED"
  log "!!! REBOOT_DETECTED: $1"
  REBOOT_HIT=1
  : > "$STOP_FILE"
}

check_boot_identity() {   # 每秒采样时都调；返回 0 表示发现重启
  local bs sess up
  bs=$(boot_sec); bs=${bs:-0}
  sess=$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)
  if [ "$bs" -gt "$BOOT_SEC_0" ] 2>/dev/null; then
    reboot_detected "boottime 变新：$BOOT_SEC_0 -> $bs"; return 0
  fi
  if [ -n "$sess" ] && [ -n "${BOOT_SESSION:-}" ] && [ "$sess" != "$BOOT_SESSION" ]; then
    reboot_detected "bootsessionuuid 变了：$BOOT_SESSION -> $sess"; return 0
  fi
  up=$(( $(date +%s) - bs ))
  if [ -n "${PREV_UPTIME:-}" ] && [ "$up" -lt $(( PREV_UPTIME - 5 )) ]; then
    reboot_detected "uptime 回退：${PREV_UPTIME}s -> ${up}s"; return 0
  fi
  PREV_UPTIME=$up
  return 1
}

# ================================================================ 4. 采样器（每 10s 一行）
sample_once() {
  local now up ws cpu rss loads round line
  now=$(date +%s)
  up=$(( now - BOOT_SEC_0 ))
  ws=$(ws_pid)
  cpu="-"; rss="-"
  if [ -n "$ws" ]; then
    cpu=$(/bin/ps -o %cpu= -p "$ws" 2>/dev/null | /usr/bin/tr -d ' ')
    rss=$(/bin/ps -o rss= -p "$ws" 2>/dev/null | /usr/bin/tr -d ' ')
  fi
  loads=$(/usr/bin/awk '{print $1+0; exit}' "$OUT/.loads" 2>/dev/null || echo 0)
  round=$(/usr/bin/awk '{print $1+0; exit}' "$OUT/.round" 2>/dev/null || echo 0)
  line=$(printf 'ts=%s epoch=%s up=%ss up_h=%s bootuuid=%s session=%s round=%s ws_pid=%s ws_cpu=%s ws_rss_kb=%s loads=%s front="%s"' \
    "$(ts)" "$now" "$up" "$(fmt_dur "$up")" "${BOOT_UUID:-unknown}" "${BOOT_SESSION:-unknown}" \
    "${round:--}" "${ws:--}" "${cpu:--}" "${rss:--}" "${loads:-0}" "$(front_app)")
  line="$line $(printf 'iop_ok=%s iop_src_surf=%s scanout=%s pipe_perf=%s surface_gpu_on=%s sg_waits=%s vm_alloc=%s vm_dealloc=%s vm_parked=%s res_new=%s res_free=%s heads=%s stage=%s agdc=%s k5=%s' \
    "$(cv iop_ok)" "$(cv iop_src_surf)" "$(cv scanout_copies)" "$(cv pipe_perform)" \
    "$(cv surface_gpu_on)" "$(cv surface_gpu_waits)" "$(cv vm_alloc)" "$(cv vm_dealloc)" \
    "$(cv vm_parked)" "$(cv res_new)" "$(cv res_free)" "$(cv heads_piped)" \
    "$(cf stage)" "$(cf agdc)" "$(cf agdc_k5)")"
  printf '%s\n' "$line" >> "$OUT/timeline.log"
}

sampler_loop() {
  local i
  while :; do
    [ -f "$STOP_FILE" ] && break
    sample_once
    check_boot_identity || true
    check_new_panics "sampler"
    [ -f "$STOP_FILE" ] && break
    i=0
    while [ "$i" -lt "$SAMPLE_SEC" ]; do
      [ -f "$STOP_FILE" ] && break 2
      sleep 1
      i=$((i+1))
    done
  done
}

# ================================================================ 5. 每轮采集
collect_round() {   # collect_round <n> <start_human> <start_epoch>
  local n="$1" s="$2" e rc=0 hits
  e=$(ts)
  # 5.1 统一日志（用户指定的谓词；--start/--end 限定在本轮窗口内）
  /usr/bin/log show --start "$s" --end "$e" --style compact \
    --predicate 'eventMessage CONTAINS "xegfx" OR eventMessage CONTAINS "NVMTL" OR eventMessage CONTAINS "XEMTL"' \
    > "$LOGS/round-$n.log" 2> "$LOGS/round-$n.log.err" || { log "log show 失败（round-${n}）"; rc=1; }
  # 5.2 userptr 专项（放大到 info/debug，专门捞 freeing wired page / userptr）
  /usr/bin/log show --start "$s" --end "$e" --info --debug --style compact \
    --predicate 'eventMessage CONTAINS "freeing wired page" OR eventMessage CONTAINS "userptr" OR eventMessage CONTAINS "GEM_USERPTR" OR eventMessage CONTAINS "wired page"' \
    > "$LOGS/round-$n-userptr.log" 2>/dev/null || true

  # 5.3 致命日志判定：内核 panic 字符串出现在统一日志里（即使 panic 文件还没落盘）
  hits=$(/usr/bin/grep -c 'freeing wired page' "$LOGS/round-$n.log" "$LOGS/round-$n-userptr.log" 2>/dev/null \
         | /usr/bin/awk -F: '{s+=$NF} END{print s+0}')
  if [ "${hits:-0}" -gt 0 ]; then
    {
      echo "ts=$(ts)"; echo "round=$n"; echo "hits=$hits"
      echo "note=统一日志里出现 'freeing wired page'，这就是 userptr 页引用竞态的 panic 字符串"
      /usr/bin/grep -h 'freeing wired page' "$LOGS/round-$n.log" "$LOGS/round-$n-userptr.log" 2>/dev/null | /usr/bin/head -5
    } >> "$OUT/WIRED_PAGE_HITS"
    log "!!! round-$n 统一日志命中 'freeing wired page' x$hits"
    PANIC_HIT=1
    : > "$STOP_FILE"
  fi

  # 5.4 本轮计数器快照
  {
    echo "# $(ts) round=$n"
    for c in $ACCEL_COUNTERS; do printf '%s=%s\n' "$c" "$(cv "$c")"; done
    for c in $CORE_COUNTERS; do printf '%s=%s\n' "$c" "$(cf "$c")"; done
  } > "$LOGS/round-$n-sysctl.txt"

  # 5.5 驱动环形日志（core kext 的 debug.xegfx_log；空/不可读就跳过）
  /usr/sbin/sysctl -b debug.xegfx_log > "$LOGS/round-$n-driverlog.bin" 2>/dev/null || true
  if [ ! -s "$LOGS/round-$n-driverlog.bin" ]; then
    /bin/rm -f "$LOGS/round-$n-driverlog.bin"
  fi

  # 5.6 panic 文件比对 + boot 身份比对
  check_new_panics "round-$n"
  check_boot_identity || true

  # 5.7 本轮计数器增量（写进 script.log，SUMMARY 也用它）
  snapshot_tsv "$LOGS/round-$n-counters.tsv"
  log "round-$n 采集完成：log=$(/usr/bin/wc -l < "$LOGS/round-$n.log" 2>/dev/null | /usr/bin/tr -d ' ') 行 userptr_hits=$hits"
  return $rc
}

snapshot_tsv() {   # snapshot_tsv <file>：一行 tab 分隔的 name=value，方便后处理
  local f="$1" line="ts=$(ts)" c v
  for c in $ACCEL_COUNTERS; do
    v=$(cv "$c"); case "$v" in ''|'-') v=0 ;; esac
    line="$line	$c=$v"
  done
  for c in $CORE_COUNTERS; do
    v=$(cf "$c"); case "$v" in ''|'-') v=0 ;; esac
    line="$line	$c=$v"
  done
  printf '%s\n' "$line" > "$f"
}

# ================================================================ 6. 主循环
trap 'log "收到信号，清理"; exit 130' INT
trap 'log "收到信号，清理"; exit 143' TERM
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "${SAMPLER_PID:-}" ] && /bin/kill -TERM "$SAMPLER_PID" 2>/dev/null || true
  kill_loads
  [ -n "${SAMPLER_PID:-}" ] && /usr/bin/wait "$SAMPLER_PID" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

printf '# timeline: 每 %ss 一行，key=value；counters 缺失显示为 "-"\n' "$SAMPLE_SEC" > "$OUT/timeline.log"
snapshot_tsv "$OUT/counters.first.tsv"
printf '0\n' > "$OUT/.loads"

ensure_bins
if [ ! -x "$BENCH_BIN" ] && [ ! -x "$CHURN_BIN" ]; then
  mark_degraded "no-load-binary: ca_bench2 与 soak_surface_churn 都不可用"
fi

# 先起采样器，保证 t=0 就有第一条时间线（否则第一轮开头是盲区）
sampler_loop &
SAMPLER_PID=$!
sleep 1
sample_once

say "开始压测 $(ts)（Ctrl-C 停止并出 SUMMARY）"
ROUND_NO=0
FINAL_RC=0
CA_LAUNCHES=0
CHURN_LAUNCHES=0

while :; do
  NOW=$(date +%s)
  [ "$NOW" -ge $(( RUN_START_EPOCH + TOTAL )) ] && { log "到达计划时长"; break; }
  [ -f "$STOP_FILE" ] && { log "停止标记出现（panic/reboot），退出主循环"; break; }

  ROUND_NO=$((ROUND_NO + 1))
  printf '%s\n' "$ROUND_NO" > "$OUT/.round"
  ROUND_START=$NOW
  ROUND_START_H=$(ts)
  ROUND_END=$(( ROUND_START + ROUND_SEC ))
  DEADLINE=$(( RUN_START_EPOCH + TOTAL ))
  [ "$ROUND_END" -gt "$DEADLINE" ] && ROUND_END=$DEADLINE
  RDIR="$LOGS/round-$ROUND_NO"
  mkdir -p "$RDIR"

  # 每轮开头再确认一次二进制（首轮编译失败还有机会补上；源码更新会触发重编译）
  ensure_bins
  if [ ! -x "$BENCH_BIN" ] || [ ! -x "$CHURN_BIN" ]; then
    if [ ! -f "$OUT/.bins_missing" ]; then
      : > "$OUT/.bins_missing"
      mark_degraded "missing-load-binary round=$ROUND_NO bench=$([ -x "$BENCH_BIN" ] && echo ok || echo missing) churn=$([ -x "$CHURN_BIN" ] && echo ok || echo missing)"
    fi
  fi

  log "--- round-$ROUND_NO start ${ROUND_START_H}（计划 $(( ROUND_END - ROUND_START ))s）"

  # 6.1 本轮常驻负载：IOSurface 抖动（整轮不断）
  CHURN_PID=""
  if [ -x "$CHURN_BIN" ]; then
    MFLAG=""
    [ "$SOAK_METAL" = "1" ] && MFLAG="--metal"
    launch_load "$RDIR/churn.log" $(( ROUND_SEC + 15 )) \
      "$CHURN_BIN" --seconds $(( ROUND_SEC + 10 )) --windows "$CHURN_WIN" --surfaces "$CHURN_SURF" $MFLAG
    CHURN_PID=${LOAD_PID:-}
    [ -n "$CHURN_PID" ] && CHURN_LAUNCHES=$((CHURN_LAUNCHES + 1))
  fi

  # 6.2 本轮脉冲负载：ca_bench2（每个约 7s，按 CA_EVERY 补新的，保持 1-2 个窗口在动）
  NEXT_CA=$(date +%s)
  i=0
  while [ "$i" -lt "$CA_PROCS" ] && [ -x "$BENCH_BIN" ]; do
    launch_load "$RDIR/ca-start-$i.log" 20 "$BENCH_BIN"
    [ -n "${LOAD_PID:-}" ] && CA_LAUNCHES=$((CA_LAUNCHES + 1))
    i=$((i+1))
    sleep 1
    [ -f "$STOP_FILE" ] && break
  done

  # 6.3 轮内节拍：补 CA 实例、看 churn 是否早退、刷新 .loads 给采样器
  while :; do
    NOW=$(date +%s)
    [ "$NOW" -ge "$ROUND_END" ] && break
    [ -f "$STOP_FILE" ] && break
    if [ "$NOW" -ge "$NEXT_CA" ] && [ -x "$BENCH_BIN" ]; then
      launch_load "$RDIR/ca-tick-$NOW.log" 20 "$BENCH_BIN"
      [ -n "${LOAD_PID:-}" ] && CA_LAUNCHES=$((CA_LAUNCHES + 1))
      NEXT_CA=$(( NOW + CA_EVERY ))
    fi
    # churn 早退就补一个（只在轮内剩余 >15s 时补，避免收尾时又起一个）
    if [ -x "$CHURN_BIN" ] && [ -n "${CHURN_PID:-}" ] && ! /bin/kill -0 "$CHURN_PID" 2>/dev/null; then
      if [ $(( ROUND_END - NOW )) -gt 15 ]; then
        launch_load "$RDIR/churn-restart.log" $(( ROUND_END - NOW + 10 )) \
          "$CHURN_BIN" --seconds $(( ROUND_END - NOW + 5 )) --windows "$CHURN_WIN" --surfaces "$CHURN_SURF" $MFLAG
        CHURN_PID=${LOAD_PID:-}
        [ -n "$CHURN_PID" ] && CHURN_LAUNCHES=$((CHURN_LAUNCHES + 1))
      fi
    fi
    reap_loads
    printf '%s\n' "$(printf '%s' "$LOAD_PIDS" | /usr/bin/awk '{print NF}')" > "$OUT/.loads"
    sleep 2
  done

  # 6.4 收尾本轮负载（先 TERM 再 KILL，避免 perl alarm 还没到就把进程留下）
  kill_loads
  sleep 1

  # 6.5 采集 + 判定
  collect_round "$ROUND_NO" "$ROUND_START_H" "$ROUND_START"
  [ "$PANIC_HIT" = "1" ] && { log "round-$ROUND_NO 检测到 panic 证据，准备退出"; break; }
  [ "$REBOOT_HIT" = "1" ] && { log "round-$ROUND_NO 检测到重启，准备退出"; break; }
done

# ================================================================ 7. 收尾 + SUMMARY
[ -n "${SAMPLER_PID:-}" ] && { /bin/kill -TERM "$SAMPLER_PID" 2>/dev/null; /usr/bin/wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""; }
kill_loads

# 结束状态：再抓一次 panic / boot / sysctl 全量
check_new_panics "final"
check_boot_identity || true
# 采样器是子 shell，它置的 PANIC_HIT/REBOOT_HIT 传不回来；以落盘证据为准重新对齐，
# 否则 SUMMARY 会出现"verdict=panic 但 panic=0"这种自相矛盾的行
[ -s "$OUT/PANIC_DETECTED" ] && PANIC_HIT=1
[ -s "$OUT/REBOOT_DETECTED" ] && REBOOT_HIT=1
snapshot_tsv "$OUT/counters.last.tsv"
/usr/sbin/sysctl -a 2>/dev/null | /usr/bin/grep -E '^debug\.(xegfx|nvaccel|nmxaccel)' \
  > "$OUT/sysctl-at-end.txt" || true
kext_lines > "$OUT/kexts-at-end.txt" || true

RUN_END_EPOCH=$(date +%s)
ELAPSED=$(( RUN_END_EPOCH - RUN_START_EPOCH ))

# 7.1 平均 fps / 总迭代数：从各轮 churn.log 里抓
# 每个 churn 日志取"最后一行统计"（FINAL 或每秒的 t= 行；被 kill 时只有后者）
FPS_STATS=$(for f in "$LOGS"/round-*/churn.log "$LOGS"/round-*/churn-restart.log; do
  [ -f "$f" ] || continue
  /usr/bin/awk '
    /^(FINAL|t=)/ {
      for (i = 1; i <= NF; i++) { split($i, kv, "=")
        if (kv[1] == "iter") it = kv[2]; else if (kv[1] == "fps") fp = kv[2]; else if (kv[1] == "surf") sf = kv[2] }
    }
    END { printf "%d %.1f %d %d\n", (fp > 0 ? 1 : 0), (fp > 0 ? fp : 0), it + 0, sf + 0 }
  ' "$f"
done | /usr/bin/awk '{r+=$1; f+=$2*$1; it+=$3; sf+=$4} END {printf "%d %.1f %d %d\n", r, (r?f/r:0), it, sf}')
FPS_RUNS=$(printf '%s' "$FPS_STATS" | /usr/bin/awk '{print $1}')
FPS_AVG=$(printf '%s' "$FPS_STATS" | /usr/bin/awk '{print $2}')
CHURN_ITERS=$(printf '%s' "$FPS_STATS" | /usr/bin/awk '{print $3}')
CHURN_SURFS=$(printf '%s' "$FPS_STATS" | /usr/bin/awk '{print $4}')
[ "${FPS_RUNS:-0}" = "0" ] && FPS_AVG="-" && CHURN_ITERS=0 && CHURN_SURFS=0

# 7.2 计数器增量
read_kv() { [ -r "$1" ] || { printf '0'; return; }; /usr/bin/tr '\t' '\n' < "$1" | /usr/bin/awk -F= -v k="$2" '$1==k{print $2; exit}'; }
DELTA_ROWS=""
DELTA_ALL_ZERO=1
for c in $ACCEL_COUNTERS; do
  a=$(read_kv "$OUT/counters.first.tsv" "$c"); b=$(read_kv "$OUT/counters.last.tsv" "$c")
  a=${a:-0}; b=${b:-0}
  case "$a$b" in ''|*[!0-9]*) continue ;; esac
  d=$(( b - a ))
  [ "$d" -ne 0 ] && DELTA_ALL_ZERO=0
  DELTA_ROWS="$DELTA_ROWS$(printf '  %-20s %10s -> %-10s (%+d)' "$c" "$a" "$b" "$d")
"
done
for c in $CORE_COUNTERS; do
  a=$(read_kv "$OUT/counters.first.tsv" "$c"); b=$(read_kv "$OUT/counters.last.tsv" "$c")
  a=${a:-0}; b=${b:-0}
  case "$a$b" in ''|*[!0-9]*) continue ;; esac
  d=$(( b - a ))
  DELTA_ROWS="$DELTA_ROWS$(printf '  %-20s %10s -> %-10s (%+d)' "$c" "$a" "$b" "$d")
"
done

# 7.3 结论
VERDICT="clean"
REASON="跑满时长，没有新 panic、boot 身份未变"
if [ "$REBOOT_HIT" = "1" ]; then
  VERDICT="reboot"; REASON="检测到重启（uptime/boot 身份变化），见 REBOOT_DETECTED"
  FINAL_RC=3
elif [ "$PANIC_HIT" = "1" ]; then
  VERDICT="panic"; REASON="检测到新 panic 或 'freeing wired page' 日志，见 PANIC_DETECTED / WIRED_PAGE_HITS"
  FINAL_RC=4
elif [ "$PREV_PANIC_SUSPECT" = "yes" ]; then
  REASON="本次压测干净，但上一次 soak 之后疑似打出过 panic（PREVIOUS_RUN_PANIC_SUSPECT）"
fi
if [ -f "$OUT/DEGRADED" ]; then
  [ "$VERDICT" = "clean" ] && VERDICT="clean-degraded"
  REASON="${REASON}；环境有告警，见 DEGRADED"
fi
if [ ! -x "$BENCH_BIN" ] && [ ! -x "$CHURN_BIN" ]; then
  VERDICT="degraded"; FINAL_RC=5; REASON="两个负载都没跑起来，见 DEGRADED"
fi
if [ -s "$OUT/PANIC_DETECTED" ]; then VERDICT="panic"; FINAL_RC=4; fi

{
  echo "verdict=$VERDICT"
  echo "reason=$REASON"
  echo "ts=$(ts)"
  echo "elapsed=$(fmt_dur "$ELAPSED") rounds=$ROUND_NO"
  echo "fps_avg=$FPS_AVG churn_iterations=$CHURN_ITERS churn_surfaces=$CHURN_SURFS ca_launches=$CA_LAUNCHES"
  echo "panic_hit=$PANIC_HIT reboot_hit=$REBOOT_HIT"
  echo "out=$OUT"
} > "$OUT/RESULT"

{
  echo
  echo "================ SUMMARY $(ts) ================"
  echo "结论        : $VERDICT  ($REASON)"
  echo "运行时长    : $(fmt_dur "$ELAPSED")  (计划 $(fmt_dur "$TOTAL"))  轮数=$ROUND_NO"
  echo "boot        : start [$(boot_id)]"
  echo "              end   [$(boot_id)]"
  echo "负载        : ca_bench2 启动 ${CA_LAUNCHES} 次；churn 启动 ${CHURN_LAUNCHES} 次"
  echo "churn 统计  : 平均 ${FPS_AVG} fps，累计 ${CHURN_ITERS} 次迭代 / ${CHURN_SURFS} 个 IOSurface"
  echo "panic/reboot: panic=$PANIC_HIT reboot=$REBOOT_HIT"
  echo "证据        : $OUT"
  echo "  before.txt           启动状态（boot/kext/sysctl/panic 基线）"
  echo "  timeline.log         $(/usr/bin/wc -l < "$OUT/timeline.log" 2>/dev/null | /usr/bin/tr -d ' ') 条 ${SAMPLE_SEC}s 采样"
  echo "  logs/round-N.log     每轮统一日志（xegfx/NVMTL/XEMTL）"
  echo "  logs/round-N-userptr.log / round-N-sysctl.txt"
  echo "  PANIC_DETECTED       新 panic 清单（含匹配到的 freeing wired page 行）"
  echo "  REBOOT_DETECTED      重启证据（若有）"
  echo "  WIRED_PAGE_HITS      统一日志里的 freeing wired page 命中（若有）"
  echo "  RESULT / script.log  结论 / 全过程"
  echo "-----------------------------------------------"
  echo "计数器增量（first -> last）："
  [ "$DELTA_ALL_ZERO" = "1" ] && echo "  （全部为 0：加速器可能没在出图，检查 heads_piped / debug.nvaccel_headless）"
  printf '%s' "$DELTA_ROWS"
  echo "==============================================="
} >> "$SCRIPT_LOG"

say ""
say "================ SUMMARY $(ts) ================"
say " 结论        : $VERDICT  ($REASON)"
say " 运行时长    : $(fmt_dur "$ELAPSED") / 计划 $(fmt_dur "$TOTAL")，$ROUND_NO 轮"
say " 负载        : ca_bench2 x${CA_LAUNCHES}，churn x${CHURN_LAUNCHES}，平均 ${FPS_AVG} fps，${CHURN_SURFS} 个 IOSurface"
say " panic/reboot: panic=$PANIC_HIT reboot=$REBOOT_HIT"
say " 证据目录    : $OUT"
say "   before.txt / timeline.log / logs/round-N.log / RESULT"
say "   PANIC_DETECTED / REBOOT_DETECTED / WIRED_PAGE_HITS（命中时才存在）"
say "==============================================="
say ""

log "=== soak_userptr_test end $(ts) verdict=$VERDICT rc=$FINAL_RC"
exit "$FINAL_RC"
