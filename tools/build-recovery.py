#!/usr/bin/env python3
"""builds out/crusty-recovery-update/, what golden mode's "Update recovery from USB stick" installs, so a new recovery doesnt need the SD card back in the PC.

  tools/build-recovery.py [out/crusty-recovery-update]
  tools/sync-stick.py <stick mountpoint> out/crusty-recovery-update      (setup.sh update does both)

the folder holds the files that make up the recovery on the SD card plus a MANIFEST, one line per file:
  <destination on the panel> <file> <md5> <mode> <uid:gid>
  - the golden script and its helpers on the cards /system (p2): crestInit.sh, the stubs, app_process wrapper, dropbear + /etc/shells
  - the crusty app (companion apk) on /data, it is the golden screen and the normal crusty app in one, so the normal system gets the new version too
needs tools/build-apps.sh to have run (the companion apk), dropbear is optional.
"""
import hashlib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
GOLDEN = os.path.join(ROOT, "app", "golden")

SHELLS = "/system/bin/sh\n/system/bin/bash\n/system/bin/telnetSSHProxy\n"

# (destination, source, file name on the stick, mode, owner)
FILES = [
    ("/system/bin/crestInit.sh", os.path.join(GOLDEN, "crestInit.sh"), "crestInit.sh", "0755", "0:2000"),
    ("/system/bin/app_process", os.path.join(GOLDEN, "app_process"), "app_process", "0755", "0:2000"),
    ("/system/bin/cleanUpCache.sh", os.path.join(GOLDEN, "disabled.sh"), "disabled.sh", "0755", "0:2000"),
    ("/system/bin/crestronLocalUpgrade.sh", os.path.join(GOLDEN, "disabled.sh"), "disabled.sh", "0755", "0:2000"),
    ("/system/bin/crestronUpgrade.sh", os.path.join(GOLDEN, "disabled.sh"), "disabled.sh", "0755", "0:2000"),
    ("/system/xbin/dropbearmulti", os.path.join(ROOT, "work", "dropbear", "dropbearmulti"), "dropbearmulti", "0755", "0:2000"),
    ("/system/etc/shells", None, "shells", "0644", "0:2000"),
    ("/data/app/dev.crusty.companion-1/base.apk", os.path.join(ROOT, "work", "apps", "dev.crusty.companion.apk"),
     "companion.apk", "0644", "1000:1000"),
]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "out", "crusty-recovery-update"))
    if not os.path.exists(FILES[-1][1]):
        sys.exit("no work/apps/dev.crusty.companion.apk, run tools/build-apps.sh first")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    lines = ["# <destination> <file> <md5> <mode> <uid:gid>   (tools/build-recovery.py)"]
    for dest, src, name, mode, owner in FILES:
        target = os.path.join(out, name)
        if name == "shells":
            open(target, "w").write(SHELLS)
        elif not os.path.exists(src):
            print(f">> skipping {dest} ({os.path.relpath(src, ROOT)} not built)")
            continue
        elif not os.path.exists(target):
            shutil.copyfile(src, target)
        lines.append(f"{dest} {name} {md5(target)} {mode} {owner}")
        print(f">> {dest}")
    open(os.path.join(out, "MANIFEST"), "w").write("\n".join(lines) + "\n")
    print(f"done -> {os.path.relpath(out, os.getcwd())}  (copy it to the USB stick root, or run setup.sh update)")


if __name__ == "__main__":
    main()
