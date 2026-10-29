#!/bin/sh
# Upstream NvGfx xe 0.0.44 desktop path: head-4 boot-framebuffer registration, display-pipe
# capability publish, and one WindowServer restart with capture. Run as root.
#
# Steps: load core (stage 2) -> load upstream XeGfxAccel -> headless stages 4-7 -> igpu/fb=1/3 ->
# iop=1 -> zero-copy flip gate (falls back to the copy path) -> verify heads -> arm plugin allow +
# journal sentinel -> single WindowServer restart ->
# 200 s telemetry / samples / unified log -> final collection. The machine may freeze at the
# registration write (the display pipe goes live on the real aperture); a power cycle is the fallback.
set -u
# Repository-local files are resolved from this script. The two inputs below are genuinely
# external build/helper trees and therefore must be supplied explicitly.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${XE_PROJECT_ROOT:?set XE_PROJECT_ROOT to the external project/build tree containing build/tools/display-route-snapshot}"
: "${XE_HELPER_DIR:?set XE_HELPER_DIR to the directory containing continue_headless_stage4_7.py}"
ROOT="$XE_PROJECT_ROOT"
NI="$XE_HELPER_DIR"
TRIAL_ROOT="${XE_TRIAL_ROOT:-/Library/XeGfxTrial}"
STAMP=$(date '+%Y%m%d-%H%M%S')
TSTART=$(date '+%Y-%m-%d %H:%M:%S')
OUT="$TRIAL_ROOT/upstream-trial-$STAMP"
mkdir -p "$OUT"
exec >>"$OUT/script.log" 2>&1
echo "=== upstream xe 0.0.44 desktop trial 5 (vblank sync + measured refresh + zero-copy flip) $STAMP"
BOOT=$(/usr/sbin/sysctl -n kern.bootsessionuuid)
WS0=$(/usr/bin/pgrep -x WindowServer || echo none)
echo "boot=$BOOT ws=$WS0"
echo "$OUT" > /tmp/upstream-trial3-dir

TELEM='debug.xegfx_stage debug.xegfx_running debug.xegfx_agdc debug.xegfx_progress
debug.xegfx_agdc_k5 debug.xegfx_agdc_cmds debug.xegfx_agdc_client_set debug.xegfx_agdc_k5_link
debug.xegfx_agdc_k5_caps debug.xegfx_agdc_k5_asked debug.xegfx_agdc_maxfb debug.xegfx_agdc_refused
debug.xegfxaccel_igpu debug.xegfxaccelfb debug.xegfxaccel_iop debug.xegfxaccel_headless
debug.xegfxaccel_heads_published debug.xegfxaccel_heads_registered debug.xegfxaccel_heads_piped
debug.xegfxaccel_iop_ok debug.xegfxaccel_iop_ok_h0 debug.xegfxaccel_iop_ok_h1 debug.xegfxaccel_iop_ok_h2
debug.xegfxaccel_iop_ok_h3 debug.xegfxaccel_iop_ok_h4 debug.xegfxaccel_iop_fail debug.xegfxaccel_iop_empty
debug.xegfxaccel_iop_src_res debug.xegfxaccel_iop_src_surf debug.xegfxaccel_iop_blank
debug.xegfxaccel_iop_copy_skip debug.xegfxaccel_iop_flip debug.xegfxaccel_iop_flips
debug.xegfxaccel_iop_flip_hit debug.xegfxaccel_iop_flip_miss debug.xegfxaccel_iop_flip_stale
debug.xegfxaccel_iop_flip_unwritten debug.xegfxaccel_iop_async debug.xegfxaccel_pipe_init
debug.xegfxaccel_pipe_perform debug.xegfxaccel_pipe_complete debug.xegfxaccel_pipe_validate
debug.xegfxaccel_scanout_copies debug.xegfxaccel_res_new debug.xegfxaccel_res_free
debug.xegfxaccel_vm_alloc debug.xegfxaccel_vm_alloc_bytes debug.xegfxaccel_svdiag
debug.xegfxaccel_surface_gpu_on debug.xegfxaccel_surface_gpu_waits debug.xegfxaccel_surface_gpu_wait_max_us
debug.xegfxaccel_surface_gpu_timeouts'

dump_telemetry() {   # dump_telemetry <tag>
  local tag="$1"
  echo "--- telemetry $tag $(date '+%F %T')"
  /usr/sbin/sysctl $TELEM 2>&1 | grep -v '^sysctl: unknown oid' || true
  /usr/bin/pgrep -x WindowServer || true
  /usr/sbin/sysctl -n kern.bootsessionuuid || true
}

# stale trial artifacts from earlier attempts
rm -f /Library/GPUBundles/xemtl-allow.txt /private/tmp/xemtl-first-loss-enable

echo "=== 1. core"
if ! /usr/bin/kmutil showloaded | grep -q "org.watchthelight.XeGfx ("; then
  echo "loading core"; /usr/bin/kmutil load -b org.watchthelight.XeGfx || { echo "CORE LOAD FAILED"; exit 1; }
  sleep 1
fi
/usr/sbin/sysctl -w "debug.xegfx_env=compat.linuxkpi.i915_disable_display=1 compat.linuxkpi.i915_xegfx_no_display=1 compat.linuxkpi.i915_enable_guc=3" || true
/usr/sbin/sysctl -w debug.xegfx_wdog=60 || true
/usr/sbin/sysctl -w debug.xegfx_stage=2 || { echo "STAGE2 WRITE FAILED"; exit 1; }
i=0; while [ "$(/usr/sbin/sysctl -n debug.xegfx_stage 2>/dev/null)" != "2" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
echo "stage=$(/usr/sbin/sysctl -n debug.xegfx_stage 2>/dev/null)"

echo "=== 2. accelerator"
if ! /usr/bin/kmutil showloaded | grep -q "org.watchthelight.XeGfxAccel ("; then
  echo "loading accelerator"; /usr/bin/kmutil load -b org.watchthelight.XeGfxAccel || { echo "ACCEL LOAD FAILED"; exit 1; }
  sleep 1
fi
i=0; while ! /usr/sbin/sysctl -n debug.xegfxaccel_heads_published >/dev/null 2>&1 && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
dump_telemetry "after-accel-load"
/usr/sbin/sysctl -w debug.xegfx_stage=3 || { echo "STAGE3 WRITE FAILED"; exit 1; }
i=0; while [ "$(/usr/sbin/sysctl -n debug.xegfx_stage 2>/dev/null)" != "3" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
echo "stage=$(/usr/sbin/sysctl -n debug.xegfx_stage 2>/dev/null)"

echo "=== 3. headless stages 4-7"
/usr/bin/python3 "$NI/continue_headless_stage4_7.py" || { echo "STAGE4-7 FAILED"; exit 1; }

echo "=== 3.5 AGDC service + K5 link config (IOPresentment pairs framebuffer and pipe through AGDC)"
if [ "$(/usr/sbin/sysctl -n debug.xegfx_agdc 2>/dev/null)" != "1" ]; then
  /usr/sbin/sysctl -w debug.xegfx_agdc=1 || echo "AGDC WRITE FAILED"
  i=0; while [ "$(/usr/sbin/sysctl -n debug.xegfx_agdc 2>/dev/null)" != "1" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i+1)); done
fi
/usr/sbin/sysctl -w debug.xegfx_agdc_k5=1 || echo "K5 WRITE FAILED"
sleep 1
echo "agdc=$(/usr/sbin/sysctl -n debug.xegfx_agdc 2>/dev/null) k5=$(/usr/sbin/sysctl -n debug.xegfx_agdc_k5 2>/dev/null)"
echo "agdc fbmap=$(/usr/sbin/sysctl -n debug.xegfx_agdc_fbmap 2>/dev/null)"
echo "agdc timing=$(/usr/sbin/sysctl -n debug.xegfx_panel_timing_source 2>/dev/null)"
dump_telemetry "after-agdc-k5"

echo "=== 3.6 measured panel timing (XeGfxIntelFB reports it as the mode refresh rate)"
echo "panel timing source=$(/usr/sbin/sysctl -n debug.xegfx_panel_timing_source 2>/dev/null)"
/usr/sbin/ioreg -l -w0 -c XeGfxIntelFramebuffer 2>/dev/null | grep -o "XeGfxMeasuredPanelTiming[^,}]*" | head -2
echo "=== 4. head-4 registration (boot framebuffer as Intel panel)"
/usr/sbin/sysctl -w debug.xegfxaccel_igpu=1 >/dev/null 2>&1 || true
/usr/sbin/sysctl -w debug.xegfxaccelfb=1 || { echo "FB1 WRITE FAILED"; exit 1; }
sleep 1
dump_telemetry "after-fb1"
/usr/sbin/sysctl -w debug.xegfxaccelfb=3 || { echo "FB3 WRITE FAILED"; exit 1; }
sleep 1
dump_telemetry "after-fb3"
/usr/sbin/sysctl -w debug.xegfxaccel_iop=1 || { echo "IOP WRITE FAILED"; exit 1; }
echo "=== 3.7 zero-copy flip: point PLANE_SURF at the compositor's own pages (falls back to copy on any refusal)"
sysctl -w debug.xegfxaccel_iop_xe_flip=1 >/dev/null 2>&1 || true
sleep 1
echo "flip gate: $(sysctl -n debug.xegfxaccel_iop_xe_flip 2>/dev/null)"
echo "flip counters: $(sysctl -n debug.xegfxaccel_iop_xe_flips 2>/dev/null) / miss $(sysctl -n debug.xegfxaccel_iop_xe_flip_miss 2>/dev/null) / fail $(sysctl -n debug.xegfxaccel_iop_xe_flip_fail 2>/dev/null)"
dump_telemetry after-xe-flip
sleep 1
dump_telemetry "after-iop"
/usr/sbin/sysctl -a 2>/dev/null | grep -E 'xegfx|nmxaccel' > "$OUT/sysctl-after-register.txt" || true
/usr/sbin/sysctl -b debug.xegfx_log > "$OUT/driver-log-register.bin" 2>/dev/null || true
/usr/bin/ioreg -a -l -r -c NMXAccel > "$OUT/ioreg-after-register.plist" 2>/dev/null || true
"$ROOT/build/tools/display-route-snapshot" > "$OUT/display-route-after-register.json" 2>/dev/null || true

HP=$(/usr/sbin/sysctl -n debug.xegfxaccel_heads_piped 2>/dev/null || echo 0)
HR=$(/usr/sbin/sysctl -n debug.xegfxaccel_heads_registered 2>/dev/null || echo 0)
HPUB=$(/usr/sbin/sysctl -n debug.xegfxaccel_heads_published 2>/dev/null || echo 0)
echo "heads published=$HPUB registered=$HR piped=$HP"
if [ "$HR" != "16" ] || [ "$HP" != "16" ]; then
  echo "REGISTRATION INCOMPLETE - not restarting WindowServer"
  echo "registration_incomplete" > "$OUT/RESULT"
  exit 2
fi

echo "=== 5. single WindowServer restart with capture"
printf '# XeGfx upstream head-4 trial %s\n!WindowServer\n' "$BOOT" > /Library/GPUBundles/xemtl-allow.txt
/usr/sbin/chown root:wheel /Library/GPUBundles/xemtl-allow.txt
/bin/chmod 644 /Library/GPUBundles/xemtl-allow.txt
: > /private/tmp/xemtl-first-loss-enable
/usr/sbin/chown root:wheel /private/tmp/xemtl-first-loss-enable
/bin/chmod 644 /private/tmp/xemtl-first-loss-enable
/usr/bin/log stream --level info --style compact --predicate '(process == "kernel" AND (eventMessage CONTAINS "NMXAccel" OR eventMessage CONTAINS "xegfx")) OR (process == "WindowServer")' > "$OUT/live-unified.log" 2>&1 &
STREAM=$!
sleep 1
echo "restart request $(date '+%F %T') ws0=$WS0"
/bin/launchctl kickstart -k -p system/com.apple.WindowServer || echo "kickstart failed"
START=$(date +%s)
NEXT=30
i=0
while [ $i -lt 100 ]; do
  sleep 2
  i=$((i+1))
  EL=$(( $(date +%s) - START ))
  WS=$(/usr/bin/pgrep -x WindowServer | tr '\n' ',' || true)
  {
    echo "t=$EL ws=$WS boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid)"
    /usr/sbin/sysctl $TELEM 2>&1 | grep -v '^sysctl: unknown oid' || true
  } >> "$OUT/telemetry.log"
  if [ "$EL" -ge "$NEXT" ]; then
    WSPID=$(/usr/bin/pgrep -x WindowServer | head -1 || true)
    if [ -n "${WSPID:-}" ]; then
      /usr/bin/sample "$WSPID" 1 20 -file "$OUT/WindowServer-$NEXT.sample.txt" >/dev/null 2>&1 || true
    fi
    /usr/sbin/sysctl -b debug.xegfx_log > "$OUT/driver-log-$NEXT.bin" 2>/dev/null || true
    NEXT=$((NEXT+60))
  fi
done
kill $STREAM 2>/dev/null || true
sleep 1

echo "=== 6. final collection"
/usr/sbin/sysctl -b debug.xegfx_log > "$OUT/driver-log-final.bin" 2>/dev/null || true
/usr/sbin/sysctl -a 2>/dev/null | grep -E 'xegfx|nmxaccel' > "$OUT/sysctl-final.txt" || true
/usr/bin/ioreg -a -l -r -c NMXAccel > "$OUT/ioreg-final.plist" 2>/dev/null || true
"$ROOT/build/tools/display-route-snapshot" > "$OUT/display-route-final.json" 2>/dev/null || true
cp -f /private/tmp/xemtl-first-loss-*.jsonl "$OUT/" 2>/dev/null || true
/usr/bin/log show --start "$TSTART" --info --debug --style syslog \
  --predicate 'eventMessage CONTAINS "XEGFX_" OR eventMessage CONTAINS "NMXAccel" OR eventMessage CONTAINS "nvk-reason" OR eventMessage CONTAINS "FIRST_BACKEND_DOWN" OR eventMessage CONTAINS "Metal failed"' \
  > "$OUT/unified-diag.log" 2>/dev/null || true
dump_telemetry "final"
echo "capture_done" > "$OUT/RESULT"
echo "=== done $OUT"
