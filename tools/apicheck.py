#!/usr/bin/env python3
"""checks if an app only uses framework stuff the panels boot classpath actually has, better we find out here than the panel telling us with a crash.

  apicheck.py <boot-smali-dir> <app-smali-dir> [more app dirs...]

both dirs are baksmali output trees.
every field/method the app references on a class it doesnt define itself gets looked up in the boot classpath (superclasses + interfaces included).
whatever cant be found gets printed, each of those is a NoSuchFieldError / NoSuchMethodError / NoClassDefFoundError waiting to happen at runtime.
"""
import os
import re
import sys
from collections import defaultdict

CLS = re.compile(r"^\.class .*?(L[^;]+;)", re.M)
SUP = re.compile(r"^\.super (L[^;]+;)", re.M)
IMP = re.compile(r"^\.implements (L[^;]+;)", re.M)
FLD = re.compile(r"^\.field .*?([\w$]+):(\S+?)(?:\s|$)", re.M)
MTH = re.compile(r"^\.method .*?([\w$<>]+\([^)]*\)\S+)\s*$", re.M)
OPS = ("invoke-", "sget", "sput", "iget", "iput")
TARGET = re.compile(r"^(L[^;]+;|\[\S+?)->([\w$<>]+)(\([^)]*\)\S+|:\S+)$")


def refs(src):
    for line in src.splitlines():
        line = line.strip()
        if not line.startswith(OPS):
            continue
        m = TARGET.match(line.rsplit(", ", 1)[-1])
        if m:
            yield m.groups()


def index(root):
    classes = {}
    for d, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".smali"):
                continue
            s = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            m = CLS.search(s)
            if not m:
                continue
            sup = SUP.search(s)
            classes[m.group(1)] = {
                "super": sup.group(1) if sup else None,
                "ifaces": IMP.findall(s),
                "fields": {f"{n}:{t}" for n, t in FLD.findall(s)},
                "methods": set(MTH.findall(s)),
                "src": s,
            }
    return classes


def resolve(boot, cls, member, is_field, seen=None):
    seen = seen or set()
    if cls in seen:
        return False
    seen.add(cls)
    if cls.startswith("["):
        return True  # arrays have methods too (clone etc.), those are always there
    c = boot.get(cls)
    if c is None:
        return None
    if (member in c["fields"]) if is_field else (member in c["methods"]):
        return True
    for parent in ([c["super"]] if c["super"] else []) + c["ifaces"]:
        if resolve(boot, parent, member, is_field, seen):
            return True
    return False


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    boot = index(sys.argv[1])
    apps = {}
    for d in sys.argv[2:]:
        apps.update(index(d))
    missing = defaultdict(set)
    for name, c in apps.items():
        for cls, mem, sig in refs(c["src"]):
            if cls in apps:
                continue
            is_field = sig.startswith(":")
            member = f"{mem}{sig}" if is_field else f"{mem}{sig}"
            r = resolve(boot, cls, member, is_field)
            if r is None:
                missing[f"CLASS  {cls}"].add(name)
            elif not r:
                missing[f"{'FIELD ' if is_field else 'METHOD'} {cls}->{member}"].add(name)
    for k in sorted(missing):
        users = sorted(missing[k])
        print(f"{k}\n        used by: {', '.join(u[1:-1].rsplit('/', 1)[-1] for u in users[:6])}"
              + (f" (+{len(users) - 6})" if len(users) > 6 else ""))
    print(f"\n{len(missing)} unresolved references", file=sys.stderr)


if __name__ == "__main__":
    main()
