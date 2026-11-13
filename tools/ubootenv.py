#!/usr/bin/env python3
"""reads / edits the panels u-boot environment offline, on the image, no panel needed.

  tools/ubootenv.py [--img work/raw/p3.img] print [name...]
  tools/ubootenv.py [--img work/raw/p3.img] set name=value [name=value...]
  tools/ubootenv.py [--img work/raw/p3.img] golden      # next boot -> golden (crusty maintenance) mode
  tools/ubootenv.py [--img work/raw/p3.img] normal      # back to the normal boot

the environment lives on the SD card (fw_env.config: /dev/block/mmcblk0, offset 1 MiB, size 64 KiB, = partition p3): u32 CRC32 (little endian) of the rest, then name=value\\0 ... \\0\\0.
u-boot boots Crestrons golden fallback (SD p1 boot.img + SD p2 /system) once boot_retry reaches the threshold, Crestrons own updater sets boot_retry=10 for exactly that.
ONLY use "golden" after tools/mod-golden.py made golden mode harmless!
"""
import argparse
import struct
import sys
import zlib

SIZE = 0x10000


def load(path):
    raw = open(path, "rb").read(SIZE)
    if len(raw) < SIZE:
        sys.exit(f"{path}: shorter than {SIZE} bytes, thats not a whole env")
    crc = struct.unpack_from("<I", raw)[0]
    data = raw[4:]
    if zlib.crc32(data) & 0xffffffff != crc:
        sys.exit(f"{path}: CRC doesnt match, so either not a u-boot env or one of the redundant/flagged layouts")
    env = []
    for item in data.split(b"\0"):
        if not item:
            break
        k, _, v = item.decode("latin1").partition("=")
        env.append([k, v])
    return env


def save(path, env):
    data = b"".join(f"{k}={v}".encode("latin1") + b"\0" for k, v in env) + b"\0"
    if len(data) > SIZE - 4:
        sys.exit("environment too large, it has to fit in 64 KiB")
    data = data.ljust(SIZE - 4, b"\0")
    blob = struct.pack("<I", zlib.crc32(data) & 0xffffffff) + data
    with open(path, "r+b") as f:
        f.write(blob)


def setvars(env, pairs):
    for p in pairs:
        k, _, v = p.partition("=")
        for e in env:
            if e[0] == k:
                print(f"   {k}: {e[1]} -> {v}")
                e[1] = v
                break
        else:
            print(f"   {k}: (new) {v}")
            env.append([k, v])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", default="work/raw/p3.img")
    ap.add_argument("cmd", choices=["print", "set", "golden", "normal"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    env = load(a.img)
    if a.cmd == "print":
        for k, v in env:
            if not a.args or k in a.args:
                print(f"{k}={v}")
        return
    if a.cmd == "set":
        setvars(env, a.args)
    elif a.cmd == "golden":
        # same flags Crestrons updater sets to boot golden, DataRecoveryDone=1 and the reformat flags at 0 keep even Crestrons original golden scripts from reformatting /data
        setvars(env, ["boot_retry=10", "golden_boot_retry=0", "DataRecoveryDone=1",
                      "reformatDataPartition=0", "fwUpgrade=0", "update_golden_version=0"])
    elif a.cmd == "normal":
        setvars(env, ["boot_retry=0", "golden_boot_retry=0"])
    save(a.img, env)
    print(f"saved {a.img} (CRC updated)")


if __name__ == "__main__":
    main()
