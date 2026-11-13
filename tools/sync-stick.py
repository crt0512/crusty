#!/usr/bin/env python3
"""copies the eMMC update/restore folders to the USB stick and only writes what changed, usb sticks are slow and we dont want to wait.

  tools/sync-stick.py [--full] <stick mountpoint> <folder>...
      e.g. tools/sync-stick.py /media/$USER/STICK out/crusty-emmc-update out/crusty-emmc-restore

images come with a chunk list (<img>.chunks: one md5 per 4 MiB, made by tools/build-emmc.py).
if the stick already has the image and its chunk list we compare the two lists and only the chunks that differ get written and read back, so an update costs about as much as it changed and we never read the whole stick.
Install on the panel checks every chunk it uses against the list anyway, so a stick that went bad in between gets caught there.

--full (or no chunk list on the stick yet): compare the whole file on the stick, write what differs, then read everything back.

order is images, then their chunk lists, then MANIFEST, so an interrupted sync never leaves a MANIFEST pointing at half written images.
"""
import hashlib
import os
import sys

CHUNK = 4 << 20


def mib(n):
    return f"{n / (1 << 20):6.0f}"


def drop_cache(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)


def read_list(path):
    """chunk list -> (chunk size in bytes, [md5...]), None if its not a chunk list"""
    try:
        lines = open(path).read().split()
    except OSError:
        return None
    if len(lines) < 3 or lines[0] != "#" or lines[1] != "chunk_kib":
        return None
    return int(lines[2]) * 1024, lines[3:]


def write_chunks(src, dst, todo, size):
    """writes the chunks in `todo` from src into dst in place, then reads them back (page cache dropped first, otherwise we'd just be checking our own ram lol)"""
    with open(src, "rb") as fi, open(dst, "r+b") as fo:
        for i in todo:
            fi.seek(i * size)
            fo.seek(i * size)
            fo.write(fi.read(size))
        fo.flush()
        os.fsync(fo.fileno())
    drop_cache(dst)
    with open(src, "rb") as fi, open(dst, "rb") as fo:
        for i in todo:
            fi.seek(i * size)
            fo.seek(i * size)
            if fi.read(size) != fo.read(size):
                sys.exit(f"!! VERIFY FAILED: {dst} chunk {i}")


def sync_quick(src, dst):
    """goes by the chunk lists only and trusts the one on the stick, None if that cant work here"""
    new, old = read_list(src + ".chunks"), read_list(dst + ".chunks")
    if not new or not old or new[0] != old[0] or len(new[1]) != len(old[1]):
        return None
    if not os.path.exists(dst) or os.path.getsize(dst) != os.path.getsize(src):
        return None
    size = new[0]
    todo = [i for i, (a, b) in enumerate(zip(new[1], old[1])) if a != b]
    if todo:
        write_chunks(src, dst, todo, size)
    return min(len(todo) * size, os.path.getsize(src))


def sync_full(src, dst):
    """compares the whole file, writes what differs, reads everything back"""
    size = os.path.getsize(src)
    if not os.path.exists(dst) or os.path.getsize(dst) != size:
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            while (b := fi.read(CHUNK)):
                fo.write(b)
            fo.flush()
            os.fsync(fo.fileno())
        written = size
    else:
        todo = []
        with open(src, "rb") as fi, open(dst, "rb") as fo:
            i = 0
            while (b := fi.read(CHUNK)):
                if fo.read(len(b)) != b:
                    todo.append(i)
                i += 1
        if todo:
            write_chunks(src, dst, todo, CHUNK)
        written = min(len(todo) * CHUNK, size)
    drop_cache(dst)
    h1, h2 = hashlib.md5(), hashlib.md5()
    with open(src, "rb") as fi, open(dst, "rb") as fo:
        while (b := fi.read(CHUNK)):
            h1.update(b)
            h2.update(fo.read(len(b)))
    if h1.digest() != h2.digest():
        sys.exit(f"!! VERIFY FAILED: {dst}")
    return written


def sync_small(src, dst):
    data = open(src, "rb").read()
    if os.path.exists(dst) and open(dst, "rb").read() == data:
        return 0
    with open(dst, "wb") as fo:
        fo.write(data)
        fo.flush()
        os.fsync(fo.fileno())
    return len(data)


def check_stick(stick):
    fs = {}
    for line in open("/proc/mounts"):
        f = line.split()
        fs[f[1].replace("\\040", " ")] = f[2]   # /proc/mounts writes a space in a path as \040
    if not stick or fs.get(os.path.abspath(stick)) != "vfat":
        sys.exit(f"{stick!r} isnt a mounted FAT32 stick (mount it first, e.g. udisksctl mount -b /dev/sdX1)")


def main():
    args = sys.argv[1:]
    full = "--full" in args
    args = [x for x in args if x != "--full"]
    if len(args) < 2:
        sys.exit(__doc__)
    stick = args[0]
    check_stick(stick)
    total_w = total = 0
    for src_dir in args[1:]:
        name = os.path.basename(os.path.normpath(src_dir))
        dst_dir = os.path.join(stick, name)
        os.makedirs(dst_dir, exist_ok=True)
        files = sorted(os.listdir(src_dir))
        images = [f for f in files if f.endswith(".img")]
        lists = [f for f in files if f.endswith(".chunks")]
        rest = [f for f in files if f not in images and f not in lists]   # MANIFEST goes last, see the top of the file
        for f in images + lists + rest:
            s, d = os.path.join(src_dir, f), os.path.join(dst_dir, f)
            size = os.path.getsize(s)
            how = "by chunk list"
            if f.endswith(".img"):
                w = None if full else sync_quick(s, d)
                if w is None:
                    how, w = "full compare", sync_full(s, d)
            else:
                how, w = "", sync_small(s, d)
            total_w += w
            total += size
            if f.endswith(".img") or w:
                print(f"   {name}/{f:22s} {mib(w)} of {mib(size)} MiB written  {how}", flush=True)
    os.sync()
    print(f"done: {total_w >> 20} MiB written of {total >> 20} MiB")


if __name__ == "__main__":
    main()
