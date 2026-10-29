#!/bin/bash
# Manual post-boot bring-up using the trial script checked into this repository.
# External build/helper trees are configured by run_upstream_trial5.sh; this wrapper never
# reaches back into a dated development workspace.
# Boots unaccelerated on purpose; run this once, it arms the GPU, restarts WindowServer once,
# and leaves the K9b 60fps deferred-flip mode armed for the new WindowServer session.
set -uo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TRIAL_SCRIPT="$SCRIPT_DIR/run_upstream_trial5.sh"
[ -f "$TRIAL_SCRIPT" ] || { echo "missing trial script: $TRIAL_SCRIPT" >&2; exit 2; }
STAMP=$(date +%Y%m%d-%H%M%S)
L=/Library/XeGfxTrial/resume-bringup-$STAMP.log
exec > >(tee -a "$L") 2>&1
echo "== XeGfx manual bring-up $STAMP =="
echo "boot: $(sysctl -n kern.boottime)"; echo "uuid: $(sysctl -n kern.bootsessionuuid)"
echo "ws: $(pgrep -x WindowServer)"; echo "console: $(stat -f '%Su' /dev/console)"
echo "installed core: $(shasum -a 256 /Library/Extensions/XeGfx.kext/Contents/MacOS/XeGfx | cut -c1-16)"
ST=$(sysctl -n debug.xegfx_stage 2>/dev/null)
if [ -n "${ST:-}" ]; then
  echo "NOTE: core already armed (stage=$ST); skipping bring-up"
else
  /usr/bin/touch /private/tmp/xemtl-ws-nowait
  /usr/sbin/chown root:wheel /private/tmp/xemtl-ws-nowait 2>/dev/null
  /bin/chmod 644 /private/tmp/xemtl-ws-nowait 2>/dev/null
  echo "-- start proven bring-up script (run_upstream_trial5.sh) --"
  /bin/sh "$TRIAL_SCRIPT" > /private/tmp/bringup-26night.out 2>&1 &
  BP=$!
  echo "bringup pid=$BP"
  for i in $(seq 1 300); do
    if sysctl -n debug.xegfxaccel_iop_xe_defer >/dev/null 2>&1; then
      sysctl -w debug.xegfxaccel_iop_xe_defer=1 >/dev/null 2>&1 && echo "  defer=1"
      sysctl -w debug.xegfxaccel_iop_xe_report_busy=1 >/dev/null 2>&1 && echo "  report_busy=1"
      sysctl -w debug.xegfxaccel_iop_xe_wait_idle=1 >/dev/null 2>&1 && echo "  wait_idle=1"
      sysctl -w debug.xegfxaccel_iop_xe_idle_ms=40 >/dev/null 2>&1 && echo "  idle_ms=40"
      break
    fi
    sleep 1
  done
  for i in $(seq 1 480); do kill -0 $BP 2>/dev/null || break; sleep 1; done
  wait $BP 2>/dev/null; echo "bringup rc=$?"
  # re-assert the K9b deferred-flip mode + nowait sentinel for the restarted WindowServer
  /usr/bin/touch /private/tmp/xemtl-ws-nowait 2>/dev/null
  for kv in xegfxaccel_iop_xe_defer=1 xegfxaccel_iop_xe_report_busy=1 xegfxaccel_iop_xe_wait_idle=1 xegfxaccel_iop_xe_idle_ms=40; do
    /usr/sbin/sysctl -w debug.$kv >/dev/null 2>&1 && echo "  re-assert $kv"
  done
fi
echo "== summary =="
for k in debug.xegfx_stage debug.xegfx_running debug.xegfxaccel_igpu debug.xegfxaccelfb debug.xegfxaccel_iop debug.xegfxaccel_heads_published debug.xegfxaccel_heads_registered debug.xegfxaccel_heads_piped debug.xegfxaccel_iop_xe_flip debug.xegfxaccel_iop_xe_defer debug.xegfxaccel_iop_xe_defer_signals debug.xegfxaccel_pipe_perform debug.xegfxaccel_pipe_complete; do
  printf '%-46s %s\n' "$k" "$(sysctl -n $k 2>/dev/null || echo MISSING)"
done
echo "trial dir: $(cat /tmp/upstream-trial3-dir 2>/dev/null)"
echo "allow file: $(cat /Library/GPUBundles/xemtl-allow.txt 2>/dev/null | tr '\n' ' ')"
ls -l /private/tmp/xemtl-ws-nowait 2>/dev/null
echo "RESULT=done log=$L"
