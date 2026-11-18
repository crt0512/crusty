#!/usr/bin/env python3
"""clears an apps' data and crash logs out of a /data image (SD card p6), offline with debugfs, install.sh does that for panels that are new to crusty.

  tools/clean-data.py [--data work/raw/p6.img] [--logs-only] [--dry-run]

same as "Clear apps' data" in golden mode (which does it on the panel), plus crash logs:
  - /data/<pkg>/* of every app except the crusty app and com.android.providers.* (settings.db lives there) and except each apps "lib" link. the apps stay installed, their folders stay.
  - the files in /tombstones, /anr and /system/dropbox (crash and system logs of the stock firmware)
what stays: the panels identity, that is all outside the apps folders (/crestron/hostname, /cresstore/dump.rdb with hostname + MAC, /misc/bluedroid, ...).
"""
import argparse
import subprocess
import sys

LOG_DIRS = ["/tombstones", "/anr", "/system/dropbox"]
KEEP_APPS = ("dev.crusty.companion", "com.android.providers.")


def entries(img, d):
    r = subprocess.run(["debugfs", "-R", f'ls -p "{d}"', img], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        f = line.split("/")   # ls -p gives "/inode/mode/uid/gid/name/size/", names with a slash cant exist so this is safe
        if len(f) < 7 or f[5] in (".", "..") or f[1] == "0":
            continue
        out.append((f[5], "dir" if f[2].startswith("04") else "file", int(f[6] or 0)))
    return out


def wipe(img, d, rm, rmdir, keep=()):
    size = 0
    for name, kind, n in entries(img, d):
        if name in keep:
            continue
        p = f"{d}/{name}"
        if kind == "dir":
            size += wipe(img, p, rm, rmdir)
            rmdir.append(p)
        else:
            rm.append(p)
            size += n
    return size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="work/raw/p6.img")
    ap.add_argument("--logs-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    rm, rmdir, size, apps = [], [], 0, 0
    for d in LOG_DIRS:
        size += wipe(a.data, d, rm, rmdir)
    logs = len(rm)
    if not a.logs_only:
        for name, kind, _ in entries(a.data, "/data"):
            if kind != "dir" or name.startswith(KEEP_APPS):
                continue
            size += wipe(a.data, f"/data/{name}", rm, rmdir, keep=("lib",))
            apps += 1
    print(f">> {logs} log files, data of {apps} apps: {len(rm)} files, {len(rmdir)} folders, {size / 1048576:.1f} MiB")
    if a.dry_run or not (rm or rmdir):
        return
    cmds = [f'rm "{p}"' for p in rm] + [f'rmdir "{p}"' for p in rmdir]   # rmdir list is depth first, children before parents
    r = subprocess.run(["debugfs", "-w", "-f", "-", a.data], input="\n".join(cmds) + "\n", capture_output=True, text=True)
    errs = [l for l in r.stderr.splitlines() if l and not l.startswith("debugfs ")]
    if errs:
        sys.exit("debugfs errors:\n" + "\n".join(errs[:10]))
    print("   removed")


if __name__ == "__main__":
    main()
