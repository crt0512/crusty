#!/usr/bin/env python3
"""splits an eMMC backup (the one crustys golden mode makes) into its partitions and unpacks them.

  tools/extract-emmc.py [work/emmc-backup] [work/emmc]

input: the backup folder (mmcblk1.part* = the whole eMMC in order, mmcblk1boot0/1.img, MD5SUMS).
the md5 of the whole thing gets checked first, --no-verify skips that if you really have to.
output, same idea as tools/extract.sh for the SD card:
  work/emmc/raw/<name>.img        every partition from the Amlogic partition table (MPT)
  work/emmc/raw/boot0.img, boot1.img   the eMMC boot areas
  work/emmc/partitions.txt        the table
  work/emmc/boot/, recovery/      unpacked Android boot images (kernel, ramdisk -> initramfs/, dtbs/)
  work/emmc/<ext4 partition>/     rdump of each ext4 partition (system, cache, data, ...)
  work/emmc/logo/                 images found in the logo partition

the Amlogic partition table lives at the start of "reserved" (0x2400000):
  "MPT\\0" char version[12] u32 count u32 checksum, then count x { char name[16]; u64 size; u64 offset; u32 mask; u32 pad }
"""
import glob
import hashlib
import os
import struct
import subprocess
import sys

os.environ["PATH"] += ":/usr/sbin:/sbin"
HERE = os.path.dirname(os.path.abspath(__file__))
MPT_OFFSET = 0x2400000


class Concat:
    """read only view over mmcblk1.part* as if it was one device"""

    def __init__(self, files):
        self.files = [(f, os.path.getsize(f)) for f in files]
        self.size = sum(s for _, s in self.files)

    def read(self, off, n):
        out = bytearray()
        base = 0
        for f, s in self.files:
            if off < base + s and n > 0:
                with open(f, "rb") as fh:
                    fh.seek(max(0, off - base))
                    chunk = fh.read(min(n, base + s - max(off, base)))
                out += chunk
                off += len(chunk)
                n -= len(chunk)
            base += s
        return bytes(out)

    def copy(self, off, size, dst):
        with open(dst, "wb") as out:
            done = 0
            while done < size:
                n = min(16 << 20, size - done)
                out.write(self.read(off + done, n))
                done += n


def parse_mpt(dev):
    hdr = dev.read(MPT_OFFSET, 24)
    if hdr[:4] != b"MPT\0":
        sys.exit("no Amlogic partition table (MPT) at 0x2400000, is that really the eMMC?")
    count = struct.unpack_from("<I", hdr, 16)[0]
    raw = dev.read(MPT_OFFSET + 24, count * 40)
    parts = []
    for i in range(count):
        name, size, off, mask = struct.unpack_from("<16sQQI", raw, i * 40)
        parts.append((name.rstrip(b"\0").decode(), off, size, mask))
    return hdr[4:16].rstrip(b"\0").decode(), parts


def fs_type(path):
    with open(path, "rb") as f:
        head = f.read(2048)
    if head[1080:1082] == b"\x53\xef":
        return "ext"
    if head.startswith(b"ANDROID!") or b"ANDROID!" in head[:4096]:
        return "bootimg"
    if head[:4] == b"\x27\x05\x19\x56":
        return "uimage"
    if all(b == 0 for b in head):
        return "empty"
    return "raw"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def unpack_bootimg(img, out):
    os.makedirs(out, exist_ok=True)
    print(run([sys.executable, os.path.join(HERE, "bootimg.py"), "unpack", img, out]).stdout.strip().replace("\n", "\n      "))
    k = os.path.join(out, "kernel")
    if os.path.exists(k):
        r = run([sys.executable, os.path.join(HERE, "uimage.py"), k, os.path.join(out, "zImage")])
        print("      " + r.stdout.strip())
    rd = os.path.join(out, "ramdisk")
    if os.path.exists(rd):
        d = os.path.join(out, "initramfs")
        os.makedirs(d, exist_ok=True)
        subprocess.run(f"(gzip -dc ../ramdisk 2>/dev/null || lz4 -dc ../ramdisk 2>/dev/null || cat ../ramdisk) "
                       f"| cpio -idm --quiet --no-absolute-filenames 2>/dev/null", shell=True, cwd=d)
        print(f"      initramfs: {len(os.listdir(d))} entries")
    for f in ("dtb", "second"):
        p = os.path.join(out, f)
        if os.path.exists(p):
            r = run([sys.executable, os.path.join(HERE, "dtb.py"), "split", p, os.path.join(out, "dtbs")])
            if r.returncode == 0:
                print("      dtbs: " + " ".join(l.split()[0] for l in r.stdout.splitlines()))
                break


def parse_aml_res(data, base=0):
    """Amlogic AML_RES! (v2) container: 0x40 byte header, then 0x40 byte item headers, start/next are relative to the container.
    item header: { u32 magic 0x27051956; u32 crc; u32 size; u32 start; u32 0; u32 next; u32 0; u8 idx, cnt; u16 pad; char name[32] }"""
    if data[base + 8:base + 16] != b"AML_RES!":
        return None
    version, = struct.unpack_from("<I", data, base + 4)
    count, = struct.unpack_from("<I", data, base + 20)
    items, h = [], base + 0x40
    for _ in range(count):
        magic, crc, size, start = struct.unpack_from("<IIII", data, h)
        if magic != 0x27051956:
            break
        nxt, = struct.unpack_from("<I", data, h + 20)
        name = data[h + 32:h + 64].split(b"\0")[0].decode("latin1")
        items.append((name, base + start, size))
        if not nxt:
            break
        h = base + nxt
    return version, items


def unpack_logo(img, out):
    """logo partition: AML_RES! container(s) with named BMPs in them ("bootup" = the u-boot boot logo)"""
    os.makedirs(out, exist_ok=True)
    data = open(img, "rb").read()
    found = False
    for base in range(0, len(data), 0x100000):          # theres more than one copy of the container, they sit on 1 MiB boundaries
        r = parse_aml_res(data, base)
        if not r:
            continue
        found = True
        version, items = r
        print(f"      AML_RES v{version} at 0x{base:x}: {len(items)} images")
        for name, start, size in items:
            blob = data[start:start + size]
            dims = ""
            if blob[:2] == b"BM":
                w, hh = struct.unpack_from("<ii", blob, 18)
                bpp, = struct.unpack_from("<H", blob, 28)
                dims = f"{w}x{abs(hh)} {bpp}bpp"
            fn = os.path.join(out, f"{name}{'' if base == 0 else f'@{base:x}'}.bmp")
            open(fn, "wb").write(blob)
            print(f"        {os.path.basename(fn):32s} {size:8d} bytes  {dims}")
    if not found:
        print(f"      no AML_RES container (header: {data[:16]!r})")


def main():
    src = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "work/emmc-backup")
    out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "work/emmc")
    files = sorted(glob.glob(os.path.join(src, "mmcblk1.part*")))
    if not files:
        sys.exit(f"no mmcblk1.part* in {src}")
    dev = Concat(files)
    print(f">> eMMC: {len(files)} parts, {dev.size} bytes")

    md5 = os.path.join(src, "MD5SUMS")
    if os.path.exists(md5) and "--no-verify" not in sys.argv:
        want = open(md5).read().split()[0]
        h = hashlib.md5()
        for f, _ in dev.files:
            with open(f, "rb") as fh:
                while (b := fh.read(16 << 20)):
                    h.update(b)
        print(f">> md5 {h.hexdigest()} " + ("OK (matches the eMMC)" if h.hexdigest() == want else f"MISMATCH (want {want})"))
        if h.hexdigest() != want:
            sys.exit("the backup is damaged, copy it from the stick again (or pass --no-verify if you like living dangerously)")

    version, parts = parse_mpt(dev)
    raw = os.path.join(out, "raw")
    os.makedirs(raw, exist_ok=True)
    with open(os.path.join(out, "partitions.txt"), "w") as t:
        t.write(f"Amlogic MPT {version}, {len(parts)} partitions\n")
        t.write(f"{'name':12s} {'offset':>12s} {'size':>12s} {'size MiB':>9s} mask\n")
        for name, off, size, mask in parts:
            t.write(f"{name:12s} 0x{off:010x} 0x{size:010x} {size >> 20:9d} {mask}\n")
    print(open(os.path.join(out, "partitions.txt")).read().rstrip())

    for b in ("boot0", "boot1"):
        p = os.path.join(src, f"mmcblk1{b}.img")
        if os.path.exists(p):
            subprocess.run(["cp", p, os.path.join(raw, f"{b}.img")])

    for name, off, size, mask in parts:
        img = os.path.join(raw, f"{name}.img")
        if not os.path.exists(img) or os.path.getsize(img) != size:
            dev.copy(off, size, img)
        kind = fs_type(img)
        print(f">> {name}: {size >> 20} MiB, {kind}")
        if kind == "bootimg":
            unpack_bootimg(img, os.path.join(out, name))
        elif kind == "ext":
            d = os.path.join(out, name)
            os.makedirs(d, exist_ok=True)
            run(["debugfs", "-R", f"rdump / {d}", img])
            print(f"      rdump -> {os.path.relpath(d)} ({sum(len(f) for _, _, f in os.walk(d))} files)")
        elif name == "logo":
            unpack_logo(img, os.path.join(out, "logo"))
    print(f"done -> {out}")


if __name__ == "__main__":
    main()
