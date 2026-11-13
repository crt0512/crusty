#!/usr/bin/env python3
"""rewrites the GCC nested functions in phh Superusers binds.c so clang stops crying about them.

every function in there looks like
    int f(...) { static T _x; ... auto void cb(...) { ... uses _x ... } foreach(cb, NULL); ... }
the callbacks only touch the *static* variables of the function around them, so they can become plain static functions: the statics move to file scope as f__name and cb becomes f__cb above f.
Usage: unnest.py in.c out.c
"""
import re
import sys


def match_brace(s, i):
    """index right after the '}' that closes the '{' at s[i]"""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    raise ValueError("unbalanced braces")


src = open(sys.argv[1]).read()
out, pos, n = [], 0, 0
for m in re.finditer(r"^([a-z][\w \*]*?\b(\w+)\s*\([^)]*\)\s*)\{", src, re.M):
    if m.start() < pos:
        continue
    fname = m.group(2)
    body_start = m.end() - 1
    body_end = match_brace(src, body_start)
    body = src[body_start:body_end]
    if "auto void cb(" not in body:
        continue
    statics = re.findall(r"^\s*static\s+([\w ]+?\**)\s*(\w+)(\s*=\s*[^;]+)?;\s*$", body, re.M)
    names = [s[1] for s in statics]
    body = re.sub(r"^\s*static\s+[\w ]+?\**\s*\w+(\s*=\s*[^;]+)?;\s*\n", "", body, flags=re.M)
    for nm in names:
        body = re.sub(rf"\b{nm}\b", f"{fname}__{nm}", body)
    c0 = body.index("auto void cb(")
    c1 = match_brace(body, body.index("{", c0))
    cb = "static void " + fname + "__cb" + body[c0 + len("auto void cb"):c1]
    body = body[:c0] + body[c1:]
    body = re.sub(r"\bcb\b", f"{fname}__cb", body)
    decls = "".join(f"static {t} {fname}__{nm}{init or ''};\n" for t, nm, init in statics)
    out.append(src[pos:m.start()])
    out.append(f"/* unnested by crusty tools/su/unnest.py (was a GCC nested function) */\n{decls}{cb}\n\n")
    out.append(m.group(1) + body)
    pos = body_end
    n += 1
out.append(src[pos:])
open(sys.argv[2], "w").write("".join(out))
print(f"   unnest: {n} nested callbacks rewritten")
