#!/usr/bin/env python3
"""prints a U-Boot legacy uImage header and, if you give it an output file, strips the header off so you get the raw payload (zImage).

  uimage.py <uImage> [out-payload]
"""
import struct
import sys
import time

COMP = {0: "none", 1: "gzip", 2: "bzip2", 3: "lzma", 4: "lzo", 5: "lz4"}
d = open(sys.argv[1], "rb").read()
magic, hcrc, ts, size, load, ep, dcrc, os_, arch, typ, comp = struct.unpack_from(">7I4B", d)
if magic != 0x27051956:
    sys.exit("thats not a uImage")
name = d[32:64].rstrip(b"\0").decode()
print(f"name={name!r} size={size} load=0x{load:08x} entry=0x{ep:08x} "
      f"comp={COMP.get(comp, comp)} built={time.strftime('%Y-%m-%d %H:%M', time.gmtime(ts))}")
if len(sys.argv) > 2:
    open(sys.argv[2], "wb").write(d[64:64 + size])
