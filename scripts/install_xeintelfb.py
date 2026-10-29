#!/usr/bin/env python3
"""Install the upstream NvGfx xe 0.0.44 XeGfxIntelFB kext (Intel class name on Apple's
IONDRVFramebuffer so CoreDisplay sees an Intel vendor framebuffer and WindowServer gets
IOPresentment), and rebuild the AuxKC.

The kext is new on this machine (Apple's IONDRVFramebuffer owns the panel now). Its boot guard
(NVRAM xeintelfb-starts) declines after two bad starts and -xeintelfboff disables it, so a bad
boot falls back to Apple's framebuffer. Nothing changes until the next reboot."""
import datetime, json, os, pathlib, plistlib, re, shutil, subprocess, sys

_src = os.environ.get("XEGFX_INTELFB_KEXT")
if not _src:
    raise SystemExit("XEGFX_INTELFB_KEXT is required; point it at the kext build artifact to install")
SRC = pathlib.Path(_src).expanduser().resolve()
DEST = pathlib.Path("/Library/Extensions/XeGfxIntelFB.kext")
KC = pathlib.Path("/Library/KernelCollections/AuxiliaryKernelExtensions.kc")
TRIALS = pathlib.Path("/Library/XeGfxTrial")
IDENT = "org.watchthelight.XeGfxIntelFB"


def run(args, log=None):
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    if log is not None:
        log.write("$ " + " ".join(args) + "\n" + (out.stdout or "") + (out.stderr or "") + "\n")
    return out.stdout


def sha(p):
    return subprocess.run(["/usr/bin/shasum", "-a", "256", str(p)], check=True, capture_output=True, text=True).stdout.split()[0]


def entries(path):
    r = subprocess.run(["/usr/bin/kmutil", "inspect", "-a", "x86_64", "-A", str(path)], check=True, capture_output=True, text=True)
    d = {}
    for line in r.stdout.splitlines():
        m = re.match(r"^([A-Za-z][A-Za-z0-9_.-]+)\t([^\t]+)\t", line)
        if m:
            d[m.group(1)] = m.group(2)
    return d


def main():
    if os.geteuid() != 0:
        raise SystemExit("administrator authorization is required")
    if not SRC.is_dir():
        raise RuntimeError("build artifact missing: " + str(SRC))
    existed = DEST.exists()
    if not KC.is_file():
        raise RuntimeError("AuxKC missing")
    src_info = plistlib.loads((SRC / "Contents/Info.plist").read_bytes())
    if src_info.get("CFBundleIdentifier") != IDENT:
        raise RuntimeError("unexpected kext bundle identifier: %r" % (src_info.get("CFBundleIdentifier"),))
    pers = src_info.get("IOKitPersonalities", {}).get("XeGfxIntelFramebuffer", {})
    if pers.get("IOClass") != "XeGfxIntelFramebuffer":
        raise RuntimeError("unexpected IOClass in build: %r" % (pers.get("IOClass"),))
    old_entries = entries(KC)
    upgrading = IDENT in old_entries
    TRIALS.mkdir(mode=0o755, exist_ok=True)
    stamp = datetime.datetime.now().strftime("xeintelfb-%Y%m%d-%H%M%S")
    backup = TRIALS / stamp
    backup.mkdir(mode=0o755)
    old_kc = backup / KC.name
    shutil.copy2(KC, old_kc)
    old_kext = backup / "XeGfxIntelFB.kext.before"
    if existed:
        run(["/usr/bin/ditto", str(DEST), str(old_kext)], None)
    candidate = backup / "AuxiliaryKernelExtensions.intelfb.kc"
    log = (backup / "install.log").open("w")
    state = {
        "state": "preparing",
        "backup": str(backup),
        "source": str(SRC),
        "sourceBinarySHA256": sha(SRC / "Contents/MacOS/XeGfxIntelFB"),
        "oldKCSHA256": sha(KC),
        "existed": existed,
        "upgrading": upgrading,
        "automaticReboot": False,
    }
    (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
    swapped = False
    try:
        if existed:
            run(["/bin/rm", "-rf", str(DEST)], log)
        run(["/usr/bin/ditto", str(SRC), str(DEST)], log)
        run(["/usr/sbin/chown", "-R", "root:wheel", str(DEST)], log)
        run(["/bin/chmod", "-R", "755", str(DEST)], log)
        run(["/usr/bin/plutil", "-lint", str(DEST / "Contents/Info.plist")], log)
        run(["/usr/bin/codesign", "-f", "-s", "-", "--timestamp=none", str(DEST)], log)
        run(["/usr/bin/codesign", "--verify", "--strict", str(DEST)], log)
        args = ["/usr/bin/kmutil", "create", "-n", "aux", "--volume-root", "/", "--allow-missing-kdk",
                "-B", "/System/Library/KernelCollections/BootKernelExtensions.kc",
                "-S", "/System/Library/KernelCollections/SystemKernelExtensions.kc",
                "--repository", "/Library/Extensions",
                "--repository", "/Library/Apple/System/Library/Extensions",
                "-A", str(candidate), "-z"]
        if pathlib.Path("/System/Library/Kernels/kernel").exists():
            args += ["--kernel", "/System/Library/Kernels/kernel"]
        run(args, log)
        new_entries = entries(candidate)
        if new_entries.get(IDENT) != src_info.get("CFBundleVersion"):
            raise RuntimeError("candidate intelfb version %r != %r" % (new_entries.get(IDENT), src_info.get("CFBundleVersion")))
        changed = [b for b, v in old_entries.items() if new_entries.get(b) != v]
        if changed:
            raise RuntimeError("existing AuxKC bundles changed: " + ", ".join(changed))
        if new_entries.get("org.watchthelight.XeGfx") != "0.0.44":
            raise RuntimeError("candidate core is not 0.0.44")
        if new_entries.get("org.watchthelight.XeGfxAccel") != "0.1":
            raise RuntimeError("candidate accel is not 0.1")
        uuid_text = run(["/usr/bin/kmutil", "inspect", "-a", "x86_64", "-A", str(candidate), "--show-kext-uuids"], log)
        (backup / "candidate-uuids.txt").write_text(uuid_text)
        os.chmod(candidate, 0o744)
        os.replace(candidate, KC)
        swapped = True
        with KC.open("rb") as f:
            os.fsync(f.fileno())
        state.update(
            state="installed_pending_manual_reboot",
            installedKCSHA256=sha(KC),
            newKextBinarySHA256=sha(DEST / "Contents/MacOS/XeGfxIntelFB"),
            newEntries=new_entries,
        )
        (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
        print(json.dumps(state, indent=2))
    except BaseException as exc:
        log.write("FAILED: %r\n" % (exc,))
        if swapped:
            restore = backup / "AuxiliaryKernelExtensions.restore.kc"
            shutil.copy2(old_kc, restore)
            os.replace(restore, KC)
        if existed and old_kext.exists():
            if DEST.exists():
                shutil.rmtree(DEST)
            shutil.copytree(old_kext, DEST)
        elif DEST.exists():
            shutil.rmtree(DEST)
        state.update(state="failed_disk_rolled_back", error=str(exc))
        (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
        print(json.dumps(state, indent=2))
        raise
    finally:
        log.close()


main()
