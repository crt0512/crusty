#!/usr/bin/env python3
"""tiny in place patcher for the binary AndroidManifest.xml inside an APK, no apktool needed (thank god).

  axml.py drop-home <in.apk> <out.apk> <activity-class>...

drop-home: for the given activities every <category android:name="android.intent.category.HOME"> gets pointed at "android.intent.category.DEFAULT" instead (that string is already in the pool), so the activity stops fighting for the home screen.
its a same size edit, nothing else in the file moves.
the APK has to be re-signed afterwards (tools/build-apps.sh does that).
"""
import struct
import sys
import zipfile

RES_XML_START_ELEMENT = 0x0102
RES_XML_END_ELEMENT = 0x0103
RES_STRING_POOL = 0x0001
TYPE_STRING = 0x03
HOME = "android.intent.category.HOME"
DEFAULT = "android.intent.category.DEFAULT"


def read_pool(b, off):
    _, hsize, size, count, _styles, flags, strs_start, _ = struct.unpack_from("<HHIIIIII", b, off)
    utf8 = bool(flags & 0x100)
    offsets = struct.unpack_from(f"<{count}I", b, off + hsize)
    out = []
    for o in offsets:
        p = off + strs_start + o
        if utf8:
            n = b[p]; p += 2 if n & 0x80 else 1          # utf8 pools store the utf16 length first, we dont care, skip
            n = b[p]; p += 1
            if n & 0x80:
                n = ((n & 0x7f) << 8) | b[p]; p += 1
            out.append(b[p:p + n].decode("utf-8"))
        else:
            n = struct.unpack_from("<H", b, p)[0]; p += 2
            if n & 0x8000:
                n = ((n & 0x7fff) << 16) | struct.unpack_from("<H", b, p)[0]; p += 2
            out.append(b[p:p + 2 * n].decode("utf-16le"))
    return out, off + size


def drop_home(xml, activities):
    b = bytearray(xml)
    pool, p = read_pool(b, 8)
    home, default = pool.index(HOME), pool.index(DEFAULT)
    name_attr = {i for i, s in enumerate(pool) if s == "name"}
    pkg_attr = {i for i, s in enumerate(pool) if s == "package"}
    stack, patched, package = [], 0, ""
    while p < len(b):
        ctype, hsize, csize = struct.unpack_from("<HHI", b, p)
        if ctype == RES_XML_START_ELEMENT:
            elem = pool[struct.unpack_from("<I", b, p + 20)[0]]
            astart, asize, acount = struct.unpack_from("<HHH", b, p + 24)
            attrs = []
            for i in range(acount):
                a = p + 16 + astart + i * asize
                _ns, nm, raw = struct.unpack_from("<iIi", b, a)
                dtype, data = b[a + 15], struct.unpack_from("<I", b, a + 16)[0]
                attrs.append((a, nm, raw, dtype, data))
            name = next((pool[raw] for a, nm, raw, dt, d in attrs if nm in name_attr and raw >= 0), None)
            if elem == "manifest":
                package = next((pool[raw] for a, nm, raw, dt, d in attrs if nm in pkg_attr and raw >= 0), "")
            elif elem == "activity":
                if name and name.startswith("."):
                    name = package + name
                elif name and "." not in name:
                    name = f"{package}.{name}"
                stack.append(name)
            elif elem == "category" and stack and stack[-1] in activities:
                for a, nm, raw, dt, d in attrs:
                    if nm in name_attr and raw == home:
                        struct.pack_into("<i", b, a + 8, default)          # rawValue
                        if dt == TYPE_STRING:
                            struct.pack_into("<I", b, a + 16, default)     # typedValue.data
                        patched += 1
        elif ctype == RES_XML_END_ELEMENT:
            if pool[struct.unpack_from("<I", b, p + 20)[0]] == "activity":
                stack.pop()
        p += csize
    return bytes(b), patched


def main():
    if len(sys.argv) < 5 or sys.argv[1] != "drop-home":
        sys.exit(__doc__)
    src, out, acts = sys.argv[2], sys.argv[3], set(sys.argv[4:])
    with zipfile.ZipFile(src) as zi:
        xml, n = drop_home(zi.read("AndroidManifest.xml"), acts)
        if n == 0:
            sys.exit(f"axml: no HOME category on {', '.join(sorted(acts))}, nothing to drop")
        with zipfile.ZipFile(out, "w") as zo:
            for i in zi.infolist():
                zo.writestr(i, xml if i.filename == "AndroidManifest.xml" else zi.read(i.filename))
    print(f"   manifest: removed HOME from {', '.join(sorted(acts))} ({n} filter(s))")


if __name__ == "__main__":
    main()
