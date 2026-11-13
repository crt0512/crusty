#!/usr/bin/env python3
"""splits Amlogic multi-DTBs and dumps an FDT as DTS-ish text, no dtc needed.

  dtb.py split  <multi.dtb|second> <outdir>   split AML_ multi-dtb into *.dtb
  dtb.py dump   <file.dtb>                    print the tree as text

Amlogic multi-dtb v2 layout (as found in the "second" slot of the TSW-760 boot.img):
  "AML_" u32 version u32 count
  count * { char plat[16]; char variant[16]; char board[16]; u32 offset; u32 size }
each 16 byte string is stored as 4 byte words with the byte order reversed and padded with spaces, because Amlogic.
"""
import os
import struct
import sys

FDT_MAGIC = 0xD00DFEED


def unswap(b):
    return b"".join(b[i:i + 4][::-1] for i in range(0, len(b), 4)).decode().strip()


def split(path, out):
    d = open(path, "rb").read()
    os.makedirs(out, exist_ok=True)
    if d[:4] != b"AML_":
        if struct.unpack(">I", d[:4])[0] == FDT_MAGIC:
            open(os.path.join(out, "single.dtb"), "wb").write(d)
            print("single.dtb")
            return
        sys.exit("thats neither an AML_ multi-dtb nor an FDT")
    ver, n = struct.unpack_from("<II", d, 4)
    esz = 16 * 3 + 8 if ver == 2 else 16 * 4 + 8
    for i in range(n):
        e = d[12 + i * esz: 12 + (i + 1) * esz]
        names = [unswap(e[j * 16:(j + 1) * 16]) for j in range((esz - 8) // 16)]
        off, size = struct.unpack_from("<II", e, esz - 8)
        name = "_".join(x for x in names if x)
        open(os.path.join(out, name + ".dtb"), "wb").write(d[off:off + size])
        print(f"{name}.dtb  off=0x{off:x} size={size}")


def fmt_prop(name, val):
    if not val:
        return f"{name};"
    s = val.rstrip(b"\0")
    if val.endswith(b"\0") and s and all(32 <= c < 127 or c == 0 for c in s) and b"\0\0" not in s:
        return f"{name} = " + ", ".join(f'"{x.decode()}"' for x in s.split(b"\0")) + ";"
    if len(val) % 4 == 0:
        cells = struct.unpack(f">{len(val) // 4}I", val)
        return f"{name} = <" + " ".join(f"0x{c:x}" for c in cells) + ">;"
    return f"{name} = [" + " ".join(f"{c:02x}" for c in val) + "];"


def dump(path, file=sys.stdout):
    d = open(path, "rb").read()
    magic, total, off_struct, off_strings = struct.unpack_from(">IIII", d, 0)
    if magic != FDT_MAGIC:
        sys.exit("thats not an FDT")

    def string(o):
        e = d.index(b"\0", off_strings + o)
        return d[off_strings + o:e].decode()

    p, depth = off_struct, 0
    while True:
        tok = struct.unpack_from(">I", d, p)[0]; p += 4
        if tok == 1:  # BEGIN_NODE
            e = d.index(b"\0", p); name = d[p:e].decode() or "/"
            p = (e + 4) & ~3
            print("  " * depth + name + " {", file=file); depth += 1
        elif tok == 2:  # END_NODE
            depth -= 1; print("  " * depth + "};", file=file)
        elif tok == 3:  # PROP
            ln, no = struct.unpack_from(">II", d, p); p += 8
            print("  " * depth + fmt_prop(string(no), d[p:p + ln]), file=file)
            p = (p + ln + 3) & ~3
        elif tok == 4:  # NOP
            continue
        elif tok == 9:  # END
            break


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "split":
        split(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "dump":
        dump(sys.argv[2])
    else:
        sys.exit(__doc__)
