#!/usr/bin/env python3
"""builds crustys eMMC update (and the matching restore set) out of the verified eMMC backup.

  tools/build-emmc.py [--emmc work/emmc] [--out out] [--logo branding/boot-logo.bmp]
                      [--bootanim branding/boot-animation.png] [--wallpaper branding/wallpaper.jpg]
                      [--chromium work/downloads/chromium-920003/ChromePublic.apk]

input: work/emmc/raw/{system,logo}.img from tools/extract-emmc.py (the untouched backup).
output, for the golden mode "Install" / "Restore" buttons (copy both folders to the USB stick root):
  out/crusty-emmc-update/   system.img, logo.img (crusty), MANIFEST
  out/crusty-emmc-restore/  system.img, logo.img (originals from the backup), MANIFEST
  out/emmc-build/android.policy.jar   (also used by tools/mod-golden.py for the SD card's p2)

what changes in /system (an ext4 image, edited offline with debugfs like the SD card):
  - filesystem grown from 622 MiB to the full 1 GiB partition (only 24 MiB were free)
  - Chromium 47 (2015) -> Chromium 95 (last Lollipop release, package org.chromium.chrome)
  - android.policy.jar: Home key no longer crashes (PhoneWindowManager null keyguard)
  - /system/media/bootanimation.zip: custom boot animation
  - /system/etc/default_wallpaper.png (ro.config.wallpaper): default wallpaper
  - /system/bin/crusty-boot.sh, started as root from crestInit.sh (LED permissions, su daemon)
  - root: phh's Superuser - /system/xbin/su + manager app /system/app/Superuser (tools/build-su.sh)
  - ssh: Dropbear, key-only, /system/xbin/dropbearmulti (tools/build-dropbear.sh)
  - /system/homepage: Crestron's web config app -> a small crusty page
  - lighttpd: own config serving /system/homepage, no waiting for Crestron's CPH daemon
  - crestInit.sh / logBootComplete.sh: Crestron cloud, auto-updater, partner-app installer, discovery and snmp switched off, adb no longer stopped (see CRESTINIT_OFF / LOGBOOT_OFF)
what changes in logo: the u-boot boot logo ("bootup") in both AML_RES containers, CRC recomputed.

MANIFEST format (read by app/golden/crestInit.sh):
  <partition> <file> <size KiB> <md5> <allowed current states, comma separated | *>
a state is the md5 of the whole partition, or p<KiB>:<md5> = md5 of its first KiB (for the stock ext4 partitions: the filesystem only, the unused bytes behind its end differ from panel to panel).
Install allows the original (whole + filesystem form) + every crusty image we ever built (out/emmc-history.txt).
"""
import argparse
import atexit
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

os.environ["PATH"] += ":/usr/sbin:/sbin"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LABEL = b"u:object_r:system_file:s0\0"


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while (b := f.read(16 << 20)):
            h.update(b)
    return h.hexdigest()


def run(cmd, ok=(0,), **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode not in ok:
        sys.exit(f"failed: {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r


# ------------------------------------------------------------------ logo
def bmp_classic(path):
    """any uncompressed 24 bit BMP -> one with the classic BITMAPINFOHEADER (54 byte header), same as Amlogics own"""
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        sys.exit(f"{path}: thats not a BMP")
    off, = struct.unpack_from("<I", d, 10)
    w, h = struct.unpack_from("<ii", d, 18)
    planes, bpp = struct.unpack_from("<HH", d, 26)
    comp, = struct.unpack_from("<I", d, 30)
    if bpp != 24 or comp not in (0, 3) or h <= 0:
        sys.exit(f"{path}: need an uncompressed 24-bit bottom-up BMP (got {bpp}bpp comp={comp} h={h})")
    row = (w * 3 + 3) & ~3
    pixels = d[off:off + row * h]
    hdr = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    return hdr + info + pixels, w, h


def aml_res_items(d, base):
    if d[base + 8:base + 16] != b"AML_RES!":
        return None
    count, = struct.unpack_from("<I", d, base + 20)
    items, h = [], base + 0x40
    for _ in range(count):
        magic, crc, size, start = struct.unpack_from("<IIII", d, h)
        if magic != 0x27051956:
            break
        name = d[h + 32:h + 64].split(b"\0")[0].decode("latin1")
        items.append((name, h, base + start, size))
        nxt, = struct.unpack_from("<I", d, h + 20)
        if not nxt:
            break
        h = base + nxt
    return items


def aml_res_crc(d, base):
    size, = struct.unpack_from("<I", d, base + 16)
    # looks odd but checks out against the originals: inverted crc32 over everything after the crc field itself
    return ~zlib.crc32(bytes(d[base + 4:base + size])) & 0xffffffff


def build_logo(orig, out, bmp_path):
    d = bytearray(open(orig, "rb").read())
    new, w, h = bmp_classic(bmp_path)
    changed = 0
    for base in range(0, len(d), 0x100000):
        items = aml_res_items(d, base)
        if items is None:
            continue
        if struct.unpack_from("<I", d, base)[0] != aml_res_crc(d, base):
            sys.exit(f"logo: AML_RES at 0x{base:x} has a CRC we didnt expect, so we dont understand the format, refusing")
        for name, hdr, start, size in items:
            if name != "bootup":
                continue
            ow, oh = struct.unpack_from("<ii", d, start + 18)
            if (ow, oh) != (w, h):
                sys.exit(f"logo: bootup is {ow}x{oh}, your BMP is {w}x{h}, they have to match")
            if len(new) > size:
                sys.exit(f"logo: new bootup ({len(new)} bytes) bigger than the slot ({size})")
            d[start:start + size] = new + b"\0" * (size - len(new))   # same slot, same size
            changed += 1
        struct.pack_into("<I", d, base, aml_res_crc(d, base))
    if not changed:
        sys.exit("logo: no 'bootup' image found")
    open(out, "wb").write(d)
    print(f"   logo: bootup replaced in {changed} AML_RES container(s), CRCs updated")


# ------------------------------------------------------------------ system
class Fs:
    """debugfs batch editor for an ext4 image"""

    def __init__(self, img, tmp):
        self.img, self.tmp, self.cmds = img, tmp, []
        self.gone = set()      # paths this batch already removes, exists() only sees the image as it was before the batch
        self.label = os.path.join(tmp, "label")
        open(self.label, "wb").write(LABEL)

    def q(self, cmd):
        return subprocess.run(["debugfs", "-R", cmd, self.img], capture_output=True, text=True)

    def exists(self, p):
        return p not in self.gone and "File not found" not in self.q(f"stat {p}").stderr

    def rm(self, p):
        self.cmds.append(f"rm {p}")
        self.gone.add(p)

    def meta(self, p, mode, uid=0, gid=0):
        self.cmds += [f"sif {p} uid {uid}", f"sif {p} gid {gid}", f"sif {p} mode {mode}",
                      f"ea_set -f {self.label} {p} security.selinux"]

    def put(self, local, p, mode="0100644", uid=0, gid=0):
        if self.exists(p):
            self.rm(p)
        self.cmds.append(f"write {local} {p}")
        self.gone.discard(p)
        self.meta(p, mode, uid, gid)

    def text(self, content, p, mode="0100644", uid=0, gid=0):
        local = os.path.join(self.tmp, p.strip("/").replace("/", "_"))
        open(local, "wb").write(content if isinstance(content, bytes) else content.encode())
        self.put(local, p, mode, uid, gid)

    def mkdir(self, p, mode="040755"):
        if not self.exists(p):            # existing dirs keep their owner/mode
            self.cmds.append(f"mkdir {p}")
            self.meta(p, mode)

    def ls(self, p):
        """[(name, is_dir)] from `ls -p`, which prints /ino/mode/uid/gid/name/size/"""
        out = []
        for line in self.q(f"ls -p {p}").stdout.splitlines():
            f = line.strip().split("/")
            if len(f) >= 7 and f[5] not in (".", ".."):
                out.append((f[5], f[2].startswith("04")))
        return out

    def rmtree(self, p, keep=()):
        for name, is_dir in self.ls(p):
            if name in keep:
                continue
            c = f"{p}/{name}"
            if is_dir:
                self.rmtree(c)
                self.cmds.append(f"rmdir {c}")
                self.gone.add(c)
            else:
                self.rm(c)

    def commit(self):
        cf = os.path.join(self.tmp, "cmds")
        open(cf, "w").write("\n".join(self.cmds) + "\n")
        r = subprocess.run(["debugfs", "-w", "-f", cf, self.img], capture_output=True, text=True)
        errs = [l for l in r.stderr.splitlines() if l and not l.startswith("debugfs ")]
        if errs:
            sys.exit("debugfs errors:\n" + "\n".join(errs[:20]))
        self.cmds = []


def build_policy_jar(orig_jar, out_jar, tmp):
    """android.policy.jar with the Home fix in it (tools/patches.py policy)"""
    C = os.path.join(ROOT, "work", ".cache")
    sm = os.path.join(tmp, "policy-smali")
    run(["java", "-jar", os.path.join(C, "baksmali-2.5.2.jar"), "d", "-a", "22", orig_jar, "-o", sm])
    run([sys.executable, os.path.join(HERE, "patches.py"), "policy", sm])
    dex = os.path.join(tmp, "policy-classes.dex")
    run(["java", "-jar", os.path.join(C, "smali-2.5.2.jar"), "a", "-a", "22", sm, "-o", dex])
    with zipfile.ZipFile(orig_jar) as zi, zipfile.ZipFile(out_jar, "w", zipfile.ZIP_DEFLATED) as zo:
        for i in zi.infolist():
            zo.writestr(i, open(dex, "rb").read() if i.filename == "classes.dex" else zi.read(i.filename))
    print("   android.policy.jar: Home fix")


# lines of Crestrons boot scripts we switch off, every one has to match exactly one line or the build stops (the tuple ones say how often instead)
CRESTINIT_OFF = {
    "stop adbd": "keeps adb (USB) usable",
    "start FITCProxy": "Crestron cloud",
    "start HydrogenManager": "Crestron cloud",
    "start recoverHydMgr": "Crestron cloud",
    "start redis": "CresStore, only Crestrons daemons use it",
    "start cresterrlog #TODO this should not be here, needs to be in logBootComplete.sh": "Crestron error log server",
    "start a_console": "Crestron console + its ntp loop (crusty syncs the clock itself)",
    "/system/bin/start ctpd": ("Crestrons console on TCP 41795, no login", 2),
}
LOGBOOT_OFF = {
    "/system/bin/installAPKs.sh": "(re)installs Crestron's partner apps",
    "/system/bin/restoreAppFromBackup.sh": "restores Crestron partner app data",
    "/system/bin/makeCore3CacheDir.sh": "Crestron UI cache",
    "start autoUpdater": "Crestron firmware/APK auto-update, could overwrite crusty",
    "start crestdiscovery": "Crestron network discovery",
    "start snmpd": "SNMP",
    "start cipclientd": "CIP client to a Crestron control processor",
    "start platformd": "Crestrons main daemon: forced the backlight to 255 and switched the button LEDs "
                       "off, app watchdog, periodic reboot; it also starts csio and autoUpdater",
    "start CPHProcessor": "Crestron protocol handler for its web UI",
}

# Crestron apps that are flagged persistent: Android 5 restarts those even when disabled (and loops if theyre hidden), so they have to leave the image.
# txrxservice keeps an invisible 1024x600 overlay window on top, which blocks every button that has filterTouchesWhenObscured (thanks for nothing).
REMOVE_APPS = {
    "/app/CresStreamSvc": "com.crestron.txrxservice (AirMedia/streaming, the overlay)",
    "/app/SpeechToTextService": "com.crestron.speechtotextservice",
    "/priv-app/KeyboardLanguageService": "com.crestron.service",
    "/app/JavaPlatformInterface": "com.crestron.platform (bridge to platformd)",
}


def disable_lines(text, name, lines):
    out = []
    hits = dict.fromkeys(lines, 0)
    want = {k: (v[1] if isinstance(v, tuple) else 1) for k, v in lines.items()}
    why = {k: (v[0] if isinstance(v, tuple) else v) for k, v in lines.items()}
    for l in text.split("\n"):
        key = l.strip()
        if key in lines:
            hits[key] += 1
            indent = l[:len(l) - len(l.lstrip())]
            l = f"{indent}true  # crusty: off ({why[key]}): {key}"
        out.append(l)
    bad = [k for k, n in hits.items() if n != want[k]]
    if bad:
        sys.exit(f"{name}: these lines didnt match as often as expected: {bad}")
    print(f"   {name}: {len(lines)} lines switched off")
    return "\n".join(out)


def build_wallpaper(src, out):
    """Crestrons build.prop sets ro.config.wallpaper=/system/etc/default_wallpaper.png and on Lollipop that wins over framework-res's default wallpaper, so thats the file to replace"""
    from PIL import Image
    im = Image.open(src)
    im.convert("RGB").save(out, "PNG", optimize=True)
    print(f"   wallpaper: /system/etc/default_wallpaper.png = {os.path.basename(src)} ({im.width}x{im.height})")


def build_bootanim(png, out):
    """same layout as Crestrons (402x49 frame, desc '402 49 30 / p 0 0 part0'), and the zip has to be STORED, a compressed one wont do"""
    w, h = struct.unpack(">II", open(png, "rb").read()[16:24])
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.writestr(zipfile.ZipInfo("desc.txt"), f"{w} {h} 30\np 0 0 part0\n")
        z.writestr(zipfile.ZipInfo("part0/"), b"")
        z.write(png, "part0/" + os.path.basename(png))
    print(f"   bootanimation.zip: {os.path.basename(png)} ({w}x{h})")


def build_system(orig, out, a, tmp, policy_jar):
    shutil.copyfile(orig, out)
    part_bytes = os.path.getsize(out)
    run(["e2fsck", "-fy", out], ok=(0, 1))   # exit 1 = fixed something (on Android images thats the bitmap padding)
    run(["resize2fs", out, f"{part_bytes // 4096}"])
    run(["e2fsck", "-fy", out], ok=(0, 1))   # resize2fs leaves the resize inodes i_size stale on this image, e2fsck gets to clean up after it
    blocks = re.search(r"Block count:\s+(\d+)", run(["dumpe2fs", "-h", out]).stdout).group(1)
    print(f"   system: ext4 grown to {int(blocks) * 4 // 1024} MiB (whole partition)")
    fs = Fs(out, tmp)

    # Chromium 47 -> 95
    if a.chromium and os.path.exists(a.chromium):
        for p in ("/app/org.chromium.chrome-1.apk", "/lib/libchrome_public.so"):
            if fs.exists(p):
                fs.rm(p)
        fs.mkdir("/app/ChromePublic")
        fs.mkdir("/app/ChromePublic/lib")
        fs.mkdir("/app/ChromePublic/lib/arm")
        fs.put(os.path.abspath(a.chromium), "/app/ChromePublic/ChromePublic.apk")
        with zipfile.ZipFile(a.chromium) as z:
            for n in z.namelist():
                m = re.match(r"lib/armeabi-v7a/(lib[^/]+\.so)$", n)   # crazy.libchrome.so stays in the APK
                if m:
                    local = os.path.join(tmp, m.group(1))
                    open(local, "wb").write(z.read(n))
                    fs.put(local, f"/app/ChromePublic/lib/arm/{m.group(1)}")
        print(f"   Chromium: {os.path.basename(a.chromium)} -> /system/app/ChromePublic (old Chromium 47 removed)")
    else:
        print("   Chromium: skipped (no --chromium APK)")

    fs.put(policy_jar, "/framework/android.policy.jar")

    # root: phh's Superuser (tools/build-su.sh), su daemon + the manager app as a system app
    su_bin = os.path.join(ROOT, "work", "su", "su")
    su_app = os.path.join(ROOT, "work", "su", "me.phh.superuser.apk")
    if os.path.exists(su_bin) and os.path.exists(su_app):
        fs.mkdir("/xbin")
        fs.put(su_bin, "/xbin/su", "0100755")
        fs.mkdir("/app/Superuser")
        fs.put(su_app, "/app/Superuser/Superuser.apk")
        print("   su: /system/xbin/su + /system/app/Superuser (phh Superuser, daemon started by crusty-boot.sh)")
    else:
        print("   su: skipped (run tools/build-su.sh first)")

    # ssh server (tools/build-dropbear.sh), crusty-boot.sh starts it once keys are set up
    db = os.path.join(ROOT, "work", "dropbear", "dropbearmulti")
    if os.path.exists(db):
        fs.mkdir("/xbin")
        fs.put(db, "/xbin/dropbearmulti", "0100755")
        # Crestrons /etc/shells only lists its console proxy (and has no final newline, classy), sshds only let you in with a login shell thats listed here
        fs.text("/system/bin/sh\n/system/bin/bash\n/system/bin/telnetSSHProxy\n", "/etc/shells")
        print("   ssh: /system/xbin/dropbearmulti (Dropbear, key-only, started by crusty-boot.sh)")
    else:
        print("   ssh: skipped (run tools/build-dropbear.sh first)")

    anim = os.path.join(tmp, "bootanimation.zip")
    build_bootanim(a.bootanim, anim)
    fs.put(anim, "/media/bootanimation.zip")

    if a.wallpaper:
        wp = os.path.join(tmp, "default_wallpaper.png")
        build_wallpaper(a.wallpaper, wp)
        fs.put(wp, "/etc/default_wallpaper.png")

    # root boot hook
    fs.put(os.path.join(ROOT, "app", "emmc", "crusty-boot.sh"), "/bin/crusty-boot.sh", "0100755", 0, 2000)
    ci = fs.q("cat /bin/crestInit.sh").stdout
    if "crusty-boot.sh" not in ci:
        if not ci.startswith("#! /system/bin/bash\n"):
            sys.exit("crestInit.sh doesnt start like we expected, refusing to patch")
        fs.text(ci, "/bin/crestInit.sh.crestron", "0100644", 0, 2000)
        ci = ci.replace("#! /system/bin/bash\n", "#! /system/bin/bash\n"
                        "/system/bin/sh /system/bin/crusty-boot.sh >/dev/null 2>&1 &   # crusty root boot hook\n", 1)
    ci = disable_lines(ci, "crestInit.sh", CRESTINIT_OFF)
    fs.text(ci, "/bin/crestInit.sh", "0100755", 0, 2000)
    print("   crestInit.sh: starts /system/bin/crusty-boot.sh (root) first")
    lb = fs.q("cat /bin/logBootComplete.sh").stdout
    fs.text(disable_lines(lb, "logBootComplete.sh", LOGBOOT_OFF), "/bin/logBootComplete.sh", "0100755", 0, 2000)

    for path, what in REMOVE_APPS.items():
        if fs.exists(path):
            fs.rmtree(path)
            fs.cmds.append(f"rmdir {path}")
            fs.gone.add(path)
            print(f"   removed {path}: {what}")
        else:
            sys.exit(f"{path} not found, REMOVE_APPS needs updating")

    # web server: own config, starts right away, serves /system/homepage on /
    fs.mkdir("/etc/crusty")
    fs.put(os.path.join(ROOT, "app", "emmc", "web", "lighttpd.conf"), "/etc/crusty/lighttpd.conf")
    fs.put(os.path.join(ROOT, "app", "emmc", "web", "startlighttpd.sh"),
           "/bin/webserverscripts/startlighttpd.sh", "0100755", 0, 2000)
    print("   lighttpd: crusty config (/system/etc/crusty/lighttpd.conf), started by crusty-boot.sh")

    # Crestron web config app -> crusty page (errors/ stays, lighttpds errorfile-prefix needs it)
    fs.rmtree("/homepage", keep=("errors",))
    fs.text(open(os.path.join(ROOT, "app", "emmc", "homepage", "index.html")).read(), "/homepage/index.html")
    print("   /system/homepage: Crestron web app removed, crusty index.html (errors/ kept)")
    fs.commit()
    run(["e2fsck", "-fy", out], ok=(0, 1))
    run(["e2fsck", "-fn", out])               # the gate: has to come back clean now or the build stops
    print("   system: e2fsck clean")


CHUNK_KIB = 4096


def write_chunks(img):
    """<img>.chunks: "# chunk_kib N" then one md5 per chunk, thats what the incremental eMMC writes go by"""
    with open(img, "rb") as f, open(img + ".chunks", "w") as out:
        out.write(f"# chunk_kib {CHUNK_KIB}\n")
        while (b := f.read(CHUNK_KIB * 1024)):
            out.write(hashlib.md5(b).hexdigest() + "\n")


def fs_kib(path):
    """size of the ext2/3/4 filesystem in KiB (superblock), 0 if that isnt ext"""
    with open(path, "rb") as f:
        f.seek(1024)
        sb = f.read(1024)
    if int.from_bytes(sb[56:58], "little") != 0xEF53:
        return 0
    return int.from_bytes(sb[4:8], "little") * (1024 << int.from_bytes(sb[24:28], "little")) // 1024


def md5_prefix(path, kib):
    h = hashlib.md5()
    left = kib * 1024
    with open(path, "rb") as f:
        while left > 0:
            b = f.read(min(left, 1 << 20))
            if not b:
                break
            h.update(b)
            left -= len(b)
    return h.hexdigest()


def manifest(path, lines):
    with open(path, "w") as f:
        f.write("# <partition> <file> <size KiB> <md5> <allowed current states: md5 | p<KiB>:<md5 of the first KiB> | *>  (tools/build-emmc.py)\n")
        for l in lines:
            f.write(" ".join(l) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emmc", default="work/emmc")
    ap.add_argument("--out", default="out")
    ap.add_argument("--logo", default="branding/boot-logo.bmp")
    ap.add_argument("--bootanim", default="branding/boot-animation.png")
    ap.add_argument("--wallpaper", default="branding/wallpaper.jpg")
    ap.add_argument("--chromium", default="work/downloads/chromium-920003/ChromePublic.apk")
    a = ap.parse_args()
    raw = os.path.join(a.emmc, "raw")
    upd = os.path.join(a.out, "crusty-emmc-update")
    rst = os.path.join(a.out, "crusty-emmc-restore")
    build = os.path.join(a.out, "emmc-build")
    for d in (upd, rst, build):
        os.makedirs(d, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="crusty-emmc-")
    atexit.register(shutil.rmtree, tmp, True)

    print(">> original images (from the verified backup)")
    orig = {}
    for p in ("system", "logo"):
        src = os.path.join(raw, f"{p}.img")
        orig[p] = md5(src)
        shutil.copyfile(src, os.path.join(rst, f"{p}.img"))
        print(f"   {p}: {os.path.getsize(src) // 1024} KiB md5 {orig[p]}")

    print(">> android.policy.jar")
    policy = os.path.join(build, "android.policy.jar")
    build_policy_jar(os.path.join(a.emmc, "system", "framework", "android.policy.jar"), policy, tmp)
    print(">> logo")
    build_logo(os.path.join(raw, "logo.img"), os.path.join(upd, "logo.img"), a.logo)
    print(">> system")
    build_system(os.path.join(raw, "system.img"), os.path.join(upd, "system.img"), a, tmp, policy)

    hist_path = os.path.join(a.out, "emmc-history.txt")
    hist = {}
    if os.path.exists(hist_path):
        for line in open(hist_path):
            p, m = line.split()[:2]
            hist.setdefault(p, []).append(m)
    lines_u, lines_r = [], []
    for p in ("system", "logo"):
        f = os.path.join(upd, f"{p}.img")
        m = md5(f)
        allowed = [orig[p]]
        fk = fs_kib(os.path.join(raw, f"{p}.img"))
        if fk:
            allowed.append(f"p{fk}:{md5_prefix(os.path.join(raw, f'{p}.img'), fk)}")
        allowed += [x for x in hist.get(p, []) if x != m]
        lines_u.append((p, f"{p}.img", str(os.path.getsize(f) // 1024), m, ",".join(dict.fromkeys(allowed))))
        lines_r.append((p, f"{p}.img", str(os.path.getsize(f) // 1024), orig[p], "*"))
        if m not in hist.get(p, []):
            with open(hist_path, "a") as h:
                h.write(f"{p} {m}\n")
    for d in (upd, rst):
        for p in ("system", "logo"):
            write_chunks(os.path.join(d, f"{p}.img"))
    manifest(os.path.join(upd, "MANIFEST"), lines_u)
    manifest(os.path.join(rst, "MANIFEST"), lines_r)
    print(">> MANIFESTs")
    print(open(os.path.join(upd, "MANIFEST")).read().strip())
    print(f"done -> {upd}, {rst}  (copy both folders to the USB stick root)")


if __name__ == "__main__":
    main()
