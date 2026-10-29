#!/usr/bin/env python3
"""Install the XeGfx 0.0.44 core kext (disk layer only) and rebuild the AuxKC.

The source build artifact is never guessed from a developer workspace. Set XE_CORE_SRC
to the kext you intend to install. Run as root on the test machine; nothing changes
until the next reboot."""
import datetime, json, os, pathlib, plistlib, re, shutil, subprocess, sys

_src = os.environ.get("XE_CORE_SRC")
if not _src:
    raise SystemExit("XE_CORE_SRC is required; point it at the kext build artifact to install")
SRC = pathlib.Path(_src).expanduser().resolve()
DEST = pathlib.Path("/Library/Extensions/XeGfx.kext")
KC = pathlib.Path("/Library/KernelCollections/AuxiliaryKernelExtensions.kc")
TRIALS = pathlib.Path("/Library/XeGfxTrial")
IDENT = "org.watchthelight.XeGfx"

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
    if not SRC.is_dir(): raise RuntimeError("build artifact missing: " + str(SRC))
    if not DEST.is_dir() or not KC.is_file(): raise RuntimeError("installed core or AuxKC missing")
    src_info = plistlib.loads((SRC / "Contents/Info.plist").read_bytes())
    dst_info = plistlib.loads((DEST / "Contents/Info.plist").read_bytes())
    if src_info.get("CFBundleIdentifier") != IDENT or dst_info.get("CFBundleIdentifier") != IDENT:
        raise RuntimeError("unexpected core bundle identifier")
    src_res = src_info.get("IOKitPersonalities", {}).get("XeGfxResident", {}).get("IOResourceMatch")
    dst_res = dst_info.get("IOKitPersonalities", {}).get("XeGfxResident", {}).get("IOResourceMatch")
    if src_res != "XeGfxArm" or dst_res != "XeGfxArm":
        raise RuntimeError("startup personality changed")
    old_version = dst_info.get("CFBundleVersion")
    new_version = src_info.get("CFBundleVersion")
    old_entries = entries(KC)
    TRIALS.mkdir(mode=0o755, exist_ok=True)
    stamp = datetime.datetime.now().strftime("core-%Y%m%d-%H%M%S")
    backup = TRIALS / stamp
    backup.mkdir(mode=0o755)
    old_kc = backup / KC.name
    shutil.copy2(KC, old_kc)
    shutil.copytree(DEST, backup / "XeGfx.kext.before")
    stage = DEST.with_name(DEST.name + ".044-new")
    candidate = backup / "AuxiliaryKernelExtensions.044.kc"
    log = (backup / "install.log").open("w")
    state = {"state": "preparing", "backup": str(backup), "source": str(SRC), "sourceBinarySHA256": sha(SRC / "Contents/MacOS/XeGfx"),
             "oldVersion": old_version, "newVersion": new_version, "oldKCSHA256": sha(KC), "automaticReboot": False}
    (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
    moved_old = swapped = False
    try:
        if stage.exists(): raise RuntimeError("staging path exists")
        run(["/usr/bin/ditto", str(SRC), str(stage)], log)
        run(["/usr/sbin/chown", "-R", "root:wheel", str(stage)], log)
        run(["/bin/chmod", "-R", "755", str(stage)], log)
        run(["/usr/bin/codesign", "-f", "-s", "-", "--timestamp=none", str(stage)], log)
        run(["/usr/bin/codesign", "--verify", "--strict", str(stage)], log)
        os.rename(DEST, backup / "XeGfx.kext.original"); moved_old = True
        os.rename(stage, DEST)
        args = ["/usr/bin/kmutil", "create", "-n", "aux", "--volume-root", "/", "--allow-missing-kdk",
                "-B", "/System/Library/KernelCollections/BootKernelExtensions.kc",
                "-S", "/System/Library/KernelCollections/SystemKernelExtensions.kc",
                "--repository", "/Library/Extensions",
                "--repository", "/Library/Apple/System/Library/Extensions",
                "-A", str(candidate), "-z"]
        if pathlib.Path("/System/Library/Kernels/kernel").exists(): args += ["--kernel", "/System/Library/Kernels/kernel"]
        run(args, log)
        new_entries = entries(candidate)
        if new_entries.get(IDENT) != new_version:
            raise RuntimeError("candidate core version %r != %r" % (new_entries.get(IDENT), new_version))
        changed = [b for b, v in old_entries.items() if b != IDENT and new_entries.get(b) != v]
        if changed: raise RuntimeError("existing AuxKC bundles changed: " + ", ".join(changed))
        uuid_text = run(["/usr/bin/kmutil", "inspect", "-a", "x86_64", "-A", str(candidate), "--show-kext-uuids"], log)
        (backup / "candidate-uuids.txt").write_text(uuid_text)
        os.chmod(candidate, 0o744); os.replace(candidate, KC); swapped = True
        with KC.open("rb") as f: os.fsync(f.fileno())
        state.update(state="installed_pending_manual_reboot", installedKCSHA256=sha(KC),
                     newKextFiles={str(DEST): sha(DEST / "Contents/MacOS/XeGfx")}, newEntries=new_entries)
        (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
        print(json.dumps(state, indent=2))
    except BaseException as exc:
        log.write("FAILED: %r\n" % (exc,))
        if swapped:
            restore = backup / "AuxiliaryKernelExtensions.restore.kc"; shutil.copy2(old_kc, restore); os.replace(restore, KC)
        if stage.exists(): shutil.rmtree(stage)
        if moved_old:
            if DEST.exists(): os.rename(DEST, backup / "XeGfx.kext.failed")
            os.rename(backup / "XeGfx.kext.original", DEST)
        state.update(state="failed_disk_rolled_back", error=str(exc))
        (backup / "status.json").write_text(json.dumps(state, indent=2) + "\n")
        print(json.dumps(state, indent=2)); raise
    finally:
        log.close()

main()
