#!/usr/bin/env python3
"""incremental card write, only the chunks that differ from the image get rewritten.

  flash-diff.py <image> <device> [--only p1,p6] [--chunk-mib 4]

reads image and card side by side in chunks (O_DIRECT on the card so nothing comes out of the page cache), writes only the chunks that differ, fsyncs, then reads every written chunk back from the card and compares it again.
reading costs no flash wear, only real changes get written.
called by tools/flash.sh --incremental, which does the safety checks and the confirmation, this thing here just writes to whatever device you hand it.
"""
import argparse
import json
import mmap
import os
import subprocess
import sys
import time

SECTOR = 512


def partition_ranges(image, names):
    """byte ranges of the requested MBR partitions, taken from the images own table (not the cards)"""
    out = subprocess.run(["sfdisk", "-J", image], capture_output=True, text=True,
                         env={**os.environ, "PATH": os.environ["PATH"] + ":/usr/sbin:/sbin"})
    parts = json.loads(out.stdout)["partitiontable"]["partitions"]
    ranges = []
    for n in names:
        num = n.lstrip("p")
        match = [p for p in parts if p["node"].endswith("img" + num) or p["node"].endswith(num)]
        if not match:
            sys.exit(f"no partition {n} in {image}")
        p = match[0]
        ranges.append((p["start"] * SECTOR, (p["start"] + p["size"]) * SECTOR, n))
    return sorted(ranges)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("device")
    ap.add_argument("--only", help="comma separated partitions, e.g. p6 or p1,p6")
    ap.add_argument("--chunk-mib", type=int, default=4)
    a = ap.parse_args()

    isize = os.path.getsize(a.image)
    if isize % SECTOR:
        sys.exit("image size isnt a multiple of 512, thats no card image")
    chunk = a.chunk_mib << 20
    ranges = partition_ranges(a.image, a.only.split(",")) if a.only else [(0, isize, "whole card")]
    total = sum(e - s for s, e, _ in ranges)

    img = open(a.image, "rb")
    dev = os.open(a.device, os.O_RDWR | os.O_DIRECT | os.O_SYNC)
    devbuf = mmap.mmap(-1, chunk)      # mmap because O_DIRECT wants page aligned buffers
    outbuf = mmap.mmap(-1, chunk)
    written, scanned, t0, last = [], 0, time.time(), 0.0

    def progress(final=False):
        nonlocal last
        now = time.time()
        if not final and now - last < 0.5:
            return
        last = now
        rate = scanned / max(now - t0, 1e-6)
        wbytes = sum(n for _, n in written)
        sys.stderr.write(f"\r   scanned {human(scanned)} / {human(total)} ({100 * scanned // max(total, 1)}%)"
                         f"  {human(rate)}/s  written {human(wbytes)} in {len(written)} chunk(s)   ")
        if final:
            sys.stderr.write("\n")

    for start, end, label in ranges:
        print(f">> {label}: {human(end - start)} at offset {start}", file=sys.stderr)
        off = start
        while off < end:
            n = min(chunk, end - off)
            img.seek(off)
            want = img.read(n)
            mv = memoryview(devbuf)[:n] if n == chunk else None
            if mv is None:  # tail is shorter than a chunk, needs its own aligned buffer
                tail = mmap.mmap(-1, n)
                got_n = os.preadv(dev, [tail], off)
                have = tail[:got_n]
            else:
                got_n = os.preadv(dev, [mv], off)
                have = devbuf[:got_n]
            if have != want:
                outbuf[:n] = want
                buf = memoryview(outbuf)[:n] if n == chunk else None
                if buf is None:
                    t = mmap.mmap(-1, n); t[:n] = want; buf = t
                if os.pwritev(dev, [buf], off) != n:
                    sys.exit(f"\nshort write at offset {off}")
                written.append((off, n))
            off += n
            scanned += n
            progress()
    progress(final=True)
    os.fsync(dev)

    if not written:
        print("   card already matches the image, nothing written", file=sys.stderr)
        return
    print(f">> verifying {len(written)} written chunk(s)", file=sys.stderr)
    bad = 0
    for i, (off, n) in enumerate(written, 1):
        b = mmap.mmap(-1, n)
        os.preadv(dev, [b], off)
        img.seek(off)
        if b[:n] != img.read(n):
            bad += 1
            print(f"\n!! mismatch at offset {off}", file=sys.stderr)
        sys.stderr.write(f"\r   verified {i}/{len(written)}   ")
    sys.stderr.write("\n")
    os.close(dev)
    if bad:
        sys.exit(f"!! VERIFY FAILED: {bad} chunk(s) differ")
    print("verify OK", file=sys.stderr)


if __name__ == "__main__":
    main()
