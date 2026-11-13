#!/usr/bin/env python3
"""unpacks / repacks android boot images the way the Crestron TSW-x60 (Amlogic M8) wants them.

the TSW-760 boot.img is a classic v0 android boot image plus an Amlogic extra: header field `unused[0]` holds the size of an appended device tree blob (multi-dtb "AML" table or plain FDTs) which sits after the second stage.
the kernel in there is a U-Boot legacy uImage (magic 27051956), not a bare zImage.

Usage:
  bootimg.py unpack boot.img outdir/
  bootimg.py repack outdir/ new-boot.img
"""
import json
import os
import struct
import sys

MAGIC = b"ANDROID!"
HDR_FMT = "<8s10I16s512s32s1024s"  # v0 header (1632 bytes)
FIELDS = ["magic", "kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
          "second_size", "second_addr", "tags_addr", "page_size", "dt_size",
          "os_version", "name", "cmdline", "id", "extra_cmdline"]


def pad(n, page):
    return (n + page - 1) // page * page


def find_header(data):
    # some dumps dont have the header at offset 0 because of course they dont, so we look through the first 4K
    i = data.find(MAGIC, 0, 4096)
    if i < 0:
        sys.exit("no ANDROID! magic in the first 4K, thats not a boot image")
    return i


def unpack(path, out):
    data = open(path, "rb").read()
    base = find_header(data)
    h = dict(zip(FIELDS, struct.unpack_from(HDR_FMT, data, base)))
    page = h["page_size"]
    os.makedirs(out, exist_ok=True)
    off = base + page
    parts = {}
    for name, size in (("kernel", h["kernel_size"]), ("ramdisk", h["ramdisk_size"]),
                       ("second", h["second_size"]), ("dtb", h["dt_size"])):
        if size:
            blob = data[off:off + size]
            open(os.path.join(out, name), "wb").write(blob)
            parts[name] = size
        off += pad(size, page)
    meta = {k: (v.rstrip(b"\0").decode("latin1") if isinstance(v, bytes) else v)
            for k, v in h.items() if k != "magic"}
    meta["header_offset"] = base
    meta["id"] = h["id"].hex()
    json.dump(meta, open(os.path.join(out, "header.json"), "w"), indent=2)
    for k, v in parts.items():
        print(f"{k:8s} {v:>10d} bytes")
    print(f"page_size={page} cmdline={meta['cmdline']!r} name={meta['name']!r}")
    for k in ("kernel_addr", "ramdisk_addr", "second_addr", "tags_addr"):
        print(f"{k}=0x{h[k]:08x}")


def repack(src, out):
    import hashlib
    meta = json.load(open(os.path.join(src, "header.json")))
    page = meta["page_size"]
    blobs = {}
    for name in ("kernel", "ramdisk", "second", "dtb"):
        p = os.path.join(src, name)
        blobs[name] = open(p, "rb").read() if os.path.exists(p) else b""
    sha = hashlib.sha1()
    for name in ("kernel", "ramdisk", "second"):
        sha.update(blobs[name]); sha.update(struct.pack("<I", len(blobs[name])))
    if blobs["dtb"]:
        sha.update(blobs["dtb"]); sha.update(struct.pack("<I", len(blobs["dtb"])))
    hdr = struct.pack(HDR_FMT, MAGIC,
                      len(blobs["kernel"]), meta["kernel_addr"],
                      len(blobs["ramdisk"]), meta["ramdisk_addr"],
                      len(blobs["second"]), meta["second_addr"],
                      meta["tags_addr"], page, len(blobs["dtb"]), meta.get("os_version", 0),
                      meta["name"].encode(), meta["cmdline"].encode(),
                      sha.digest().ljust(32, b"\0"), meta["extra_cmdline"].encode())
    with open(out, "wb") as f:
        f.write(hdr.ljust(page, b"\0"))
        for name in ("kernel", "ramdisk", "second", "dtb"):
            b = blobs[name]
            f.write(b + b"\0" * (pad(len(b), page) - len(b)))
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("unpack", "repack"):
        sys.exit(__doc__)
    (unpack if sys.argv[1] == "unpack" else repack)(sys.argv[2], sys.argv[3])
