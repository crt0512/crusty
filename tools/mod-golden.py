#!/usr/bin/env python3
"""turns the golden mode /system on the SD card (p2) into crustys harmless maintenance mode.

  tools/mod-golden.py [--system work/raw/p2.img] [--dry-run]

p2 only gets booted in Crestrons "golden" fallback (normal boots use /system on the eMMC), and Crestrons golden scripts reformat /data and reflash the internal eMMC, no bueno!
so they get replaced:

  /system/bin/crestInit.sh            -> app/golden/crestInit.sh (crusty maintenance script)
  /system/bin/cleanUpCache.sh         -> app/golden/disabled.sh  (formats SD partitions)
  /system/bin/crestronLocalUpgrade.sh -> app/golden/disabled.sh  (reflashes the eMMC)
  /system/bin/crestronUpgrade.sh      -> app/golden/disabled.sh
  /system/xbin/dropbearmulti          -> work/dropbear/dropbearmulti (ssh in golden mode, only if tools/build-dropbear.sh ran) + /system/etc/shells

the originals stay around as <name>.crestron (saved once).
files get root:shell 0755 and the SELinux label u:object_r:system_file:s0 like the rest of /system.
idempotent, run it as often as you want.
"""
import argparse
import atexit
import os
import shutil
import subprocess
import sys
import tempfile

os.environ["PATH"] += ":/usr/sbin:/sbin"
HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "app", "golden")
REPLACE = {
    "crestInit.sh": "crestInit.sh",
    "cleanUpCache.sh": "disabled.sh",
    "crestronLocalUpgrade.sh": "disabled.sh",
    "crestronUpgrade.sh": "disabled.sh",
}
LABEL = b"u:object_r:system_file:s0\0"


def dbg(img, cmd):
    return subprocess.run(["debugfs", "-R", cmd, img], capture_output=True, text=True)


def exists(img, p):
    return "File not found" not in dbg(img, f"stat {p}").stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--system", default="work/raw/p2.img")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    img = a.system
    if not exists(img, "/bin/crestInit.sh") or not exists(img, "/build.prop"):
        sys.exit(f"{img} doesnt look like the golden /system (p2)")

    tmp = tempfile.mkdtemp(prefix="crusty-golden-")
    atexit.register(shutil.rmtree, tmp, True)
    label = os.path.join(tmp, "label")
    open(label, "wb").write(LABEL)
    cmds = []

    def put(local, path, mode="0100755"):
        if exists(img, path):
            cmds.append(f"rm {path}")
        cmds.extend([f"write {local} {path}", f"sif {path} uid 0", f"sif {path} gid 2000",
                     f"sif {path} mode {mode}", f"ea_set -f {label} {path} security.selinux"])

    for name, src in REPLACE.items():
        path = f"/bin/{name}"
        backup = path + ".crestron"
        if not exists(img, backup):
            orig = os.path.join(tmp, name + ".crestron")
            dbg(img, f"dump {path} {orig}")
            if os.path.getsize(orig) == 0:
                sys.exit(f"couldnt read {path}")
            if b"crusty" in open(orig, "rb").read(4096):
                sys.exit(f"{path} is already a crusty file but {backup} is missing, not touching that")
            print(f">> save original {path} -> {backup}")
            cmds.extend([f"write {orig} {backup}", f"sif {backup} uid 0", f"sif {backup} gid 2000",
                         f"sif {backup} mode 0100644", f"ea_set -f {label} {backup} security.selinux"])
        print(f">> {path} <- app/golden/{src}")
        put(os.path.abspath(os.path.join(GOLDEN, src)), path)

    # golden mode gets its own compile cache, a wrapper sits where the app_process -> app_process32 link was
    print(">> /bin/app_process <- app/golden/app_process (own dalvik-cache for golden mode)")
    put(os.path.abspath(os.path.join(GOLDEN, "app_process")), "/bin/app_process")

    # Dropbear for ssh in golden mode (the script falls back to the eMMCs copy if this isnt here)
    db = os.path.abspath(os.path.join(HERE, "..", "work", "dropbear", "dropbearmulti"))
    if os.path.exists(db):
        print(">> /xbin/dropbearmulti <- work/dropbear/dropbearmulti (+ /etc/shells, dropbear wants a listed login shell)")
        shells = os.path.join(tmp, "shells")
        open(shells, "w").write("/system/bin/sh\n/system/bin/bash\n/system/bin/telnetSSHProxy\n")
        put(db, "/xbin/dropbearmulti")
        put(shells, "/etc/shells", "0100644")
    else:
        print(">> no work/dropbear/dropbearmulti (run tools/build-dropbear.sh), golden ssh will use the eMMCs copy")

    if a.dry_run:
        print("\n".join("   debugfs: " + c for c in cmds))
        return
    cf = os.path.join(tmp, "cmds")
    open(cf, "w").write("\n".join(cmds) + "\n")
    r = subprocess.run(["debugfs", "-w", "-f", cf, img], capture_output=True, text=True)
    errs = [l for l in r.stderr.splitlines() if l and not l.startswith("debugfs ")]
    if errs:
        sys.exit("debugfs errors:\n" + "\n".join(errs))
    print("done, golden mode is now crusty maintenance mode (run tools/pack.sh next).")


if __name__ == "__main__":
    main()
