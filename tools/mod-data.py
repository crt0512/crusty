#!/usr/bin/env python3
"""applies crustys modifications to the panels /data image (SD card p6), offline.

  tools/mod-data.py [--data work/raw/p6.img] [--apps work/apps] [--config config]
                    [--system work/system] [--dry-run]

on the TSW-760 the live /data is mmcblk0p6 on the SD card (/system is on the internal eMMC), so everything here happens on /data with debugfs, no root needed:

  1. APKs in work/apps/<package>.apk
       - new package: goes to /data/app/<pkg>-1/base.apk, Android 5.1's PackageManager adopts unknown packages there at boot.
       - system package (e.g. SystemUI): same path, plus packages.xml gets rewritten so the APK is registered as an *update* of the system app (<updated-package> + codePath in /data), exactly like an installed system app update.
  2. config/disable-packages.txt   -> enabled="2" in package-restrictions.xml (like `pm disable`)
     config/disable-components.txt -> <disabled-components> (like `pm disable pkg/cls`)
     config/required-packages.txt  -> always re-enabled (e.g. if switched off in crusty)
     entries that got removed from the lists are re-enabled.
  3. config/input/buttons.kl -> side button key layout (see that file for why it needs an idc override for Vendor_0001_Product_0001)
  4. config/settings.ini -> values in settings.db / locksettings.db

idempotent.
the first run saves *.crusty-orig copies of the files it edits, so theres always a way back.
"""
import argparse
import atexit
import configparser
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

os.environ["PATH"] += ":/usr/sbin:/sbin"
RESTR = "/system/users/0/package-restrictions.xml"
PKGS = "/system/packages.xml"
STATE = "/system/users/0/crusty-state.json"
OLD_STATE = "/system/users/0/crusty-disabled.txt"
DEV_DIR = "/system/devices"
SETTINGS_DB = "/data/com.android.providers.settings/databases/settings.db"
LOCK_DB = "/system/locksettings.db"
KL_NAME = "crusty_tsw"
FLAG_UPDATED_SYSTEM_APP = 0x80


class Img:
    def __init__(self, path, dry):
        self.path, self.dry, self.cmds = path, dry, []
        self.tmp = tempfile.mkdtemp(prefix="crusty-")
        atexit.register(shutil.rmtree, self.tmp, True)

    def run(self, cmd):
        return subprocess.run(["debugfs", "-R", cmd, self.path], capture_output=True, text=True)

    def exists(self, p):
        return "File not found" not in self.run(f"stat {p}").stderr

    def cat(self, p):
        return self.run(f"cat {p}").stdout

    def dump(self, p, local):
        self.run(f"dump {p} {local}")
        return os.path.exists(local)

    def attrs(self, p):
        s = self.run(f"stat {p}").stdout
        mode = re.search(r"Mode:\s+(\d+)", s).group(1)
        uid = re.search(r"User:\s+(\d+)", s).group(1)
        gid = re.search(r"Group:\s+(\d+)", s).group(1)
        return mode, uid, gid

    def owned(self, p, mode, uid="1000", gid="1000"):
        self.cmds += [f"sif {p} uid {uid}", f"sif {p} gid {gid}", f"sif {p} mode {mode}"]

    def mkdir(self, p, mode="040775"):
        if not self.exists(p):
            self.cmds.append(f"mkdir {p}")
            self.owned(p, mode)

    def rm(self, p):
        if self.exists(p):
            self.cmds.append(f"rm {p}")

    def put(self, local, p, mode, uid="1000", gid="1000"):
        self.rm(p)
        self.cmds.append(f"write {local} {p}")
        self.owned(p, mode, uid, gid)

    def put_text(self, text, p, mode="0100660"):
        local = os.path.join(self.tmp, p.strip("/").replace("/", "_"))
        open(local, "w").write(text)
        self.put(local, p, mode)

    def backup_once(self, p, local_or_text, is_file=False):
        if self.exists(p + ".crusty-orig"):
            return
        if is_file:
            mode, uid, gid = self.attrs(p)
            self.put(local_or_text, p + ".crusty-orig", "010" + mode.lstrip("0").rjust(4, "0"), uid, gid)
        else:
            self.put_text(local_or_text, p + ".crusty-orig")

    def commit(self):
        if self.dry:
            print("\n".join("   debugfs: " + c for c in self.cmds if not c.startswith("sif ")))
            return
        cf = os.path.join(self.tmp, "cmds")
        open(cf, "w").write("\n".join(self.cmds) + "\n")
        r = subprocess.run(["debugfs", "-w", "-f", cf, self.path], capture_output=True, text=True)
        errs = [l for l in r.stderr.splitlines() if l and not l.startswith("debugfs ")]
        if errs:
            sys.exit("debugfs errors:\n" + "\n".join(errs))


def read_list(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(line)
    return out


# ---------------------------------------------------------------- packages.xml
def pkg_block(xml, pkg):
    m = re.search(r'(?ms)^(\s*)<package name="%s" .*?^\1</package>\n' % re.escape(pkg), xml)
    if not m:  # the self closing variant
        m = re.search(r'(?m)^(\s*)<package name="%s" [^>]*/>\n' % re.escape(pkg), xml)
    return m


def as_system_update(xml, pkg, data_dir):
    """turns the <package> entry of a system app into 'updated, code lives in /data', same thing Android writes when you install an update for a system app"""
    if re.search(r'<updated-package name="%s"' % re.escape(pkg), xml):
        return xml, False  # already done
    m = pkg_block(xml, pkg)
    block = m.group(0)
    head = re.match(r'\s*<package [^>]*>', block).group(0)
    attrs = dict(re.findall(r'(\w+)="([^"]*)"', head))
    sys_path = attrs["codePath"]
    keep = ["name", "codePath", "nativeLibraryPath", "primaryCpuAbi", "secondaryCpuAbi",
            "ft", "it", "ut", "version", "sharedUserId", "userId"]
    upd = " ".join(f'{k}="{attrs[k]}"' for k in keep if k in attrs)
    updated = f'{m.group(1)}<updated-package {upd} />\n'
    new_head = head.replace(f'codePath="{sys_path}"', f'codePath="{data_dir}"')
    if "nativeLibraryPath" in attrs:
        new_head = new_head.replace(f'nativeLibraryPath="{attrs["nativeLibraryPath"]}"',
                                    f'nativeLibraryPath="{data_dir}/lib"')
    flags = int(attrs["flags"]) | FLAG_UPDATED_SYSTEM_APP
    new_head = re.sub(r'flags="\d+"', f'flags="{flags}"', new_head)
    new_block = block.replace(head, new_head, 1) + updated
    return xml[:m.start()] + new_block + xml[m.end():], True


# ------------------------------------------------------ package-restrictions.xml
def pkg_entry(xml, pkg):
    """match of the <pkg name=...> element, self closing or not"""
    m = re.search(r'(?s)<pkg name="%s"[^>]*?/>' % re.escape(pkg), xml) or \
        re.search(r'(?s)<pkg name="%s"[^>]*?[^/]>.*?</pkg>' % re.escape(pkg), xml)
    return m


def set_pkg_enabled(xml, pkg, disabled):
    m = pkg_entry(xml, pkg)
    if not m:
        if disabled:
            xml = xml.replace("<package-restrictions>",
                              f'<package-restrictions>\n    <pkg name="{pkg}" enabled="2" />', 1)
        return xml
    el = m.group(0)
    head = re.match(r'<pkg [^>]*?(/?)>', el)
    attrs = re.sub(r'\s+enabled="\d+"', "", head.group(0)[len(f'<pkg name="{pkg}"'):].rstrip("/>")).rstrip()
    if disabled:
        attrs += ' enabled="2"'
    new_head = f'<pkg name="{pkg}"{attrs}' + (" />" if head.group(1) else ">")
    return xml[:m.start()] + new_head + el[head.end():] + xml[m.end():]


def set_component_disabled(xml, pkg, cls, disabled):
    item = f'<item name="{cls}" />'
    m = pkg_entry(xml, pkg)
    if not m:
        if disabled:
            xml = xml.replace("<package-restrictions>",
                              f'<package-restrictions>\n    <pkg name="{pkg}">\n        <disabled-components>\n'
                              f'            {item}\n        </disabled-components>\n    </pkg>', 1)
        return xml
    el = m.group(0)
    if el.endswith("/>") and not el.endswith("</pkg>"):  # self closing, open it up so the item fits in
        el = el[:-2].rstrip() + ">\n    </pkg>"
    has = re.search(r'<item name="%s"\s*/>' % re.escape(cls), el)
    if disabled and not has:
        if "<disabled-components>" in el:
            el = el.replace("<disabled-components>", f"<disabled-components>\n            {item}", 1)
        else:
            el = el.replace("\n    </pkg>", f"\n        <disabled-components>\n            {item}\n"
                                           f"        </disabled-components>\n    </pkg>", 1)
    elif not disabled and has:
        el = re.sub(r'\n\s*<item name="%s"\s*/>' % re.escape(cls), "", el)
        el = re.sub(r'\n\s*<disabled-components>\s*</disabled-components>', "", el)
    return xml[:m.start()] + el + xml[m.end():]


# --------------------------------------------------------------------- input
def build_input(system_dir, buttons_kl):
    """merges the system Vendor_0001_Product_0001.kl with our button lines"""
    base_kl = os.path.join(system_dir, "usr/keylayout/Vendor_0001_Product_0001.kl")
    base_idc = os.path.join(system_dir, "usr/idc/ft5x06.idc")
    ours = [l for l in open(buttons_kl) if re.match(r"\s*key\s+\d+", l)]
    scancodes = {re.match(r"\s*key\s+(\d+)", l).group(1) for l in ours}
    out = [f"# generated by crusty tools/mod-data.py from {os.path.relpath(base_kl, system_dir)}\n"
           f"# + config/input/buttons.kl\n"]
    for l in open(base_kl):
        m = re.match(r"\s*key\s+(\d+)\s", l)
        if m and m.group(1) in scancodes:
            l = "# (replaced by crusty) " + l
        out.append(l)
    out.append("\n# ---- crusty: TSW side buttons ----\n")
    out += [l.split("#", 1)[0].rstrip() + "\n" for l in ours]
    idc = open(base_idc).read().rstrip() + (
        f"\n\n# crusty: this file is matched by vendor/product 0001:0001, which the ft5x06\n"
        f"# touchscreen shares with the IR remote, GPIO power key and PMU. Point all of\n"
        f"# them at the merged layout (system Vendor_0001_Product_0001.kl + side buttons).\n"
        f"keyboard.layout = {KL_NAME}\n")
    return "".join(out), idc


# ------------------------------------------------------------------ settings
def edit_sqlite(img, path, edits, is_lock):
    """applies name=value edits to a settings style sqlite db inside the image"""
    if not img.exists(path):
        print(f"   !! {path} missing, skipped")
        return
    d = tempfile.mkdtemp(dir=img.tmp)
    local = os.path.join(d, os.path.basename(path))
    img.dump(path, local)
    side = [s for s in ("-journal", "-wal") if img.exists(path + s)]
    for s in side:  # rollback journal / WAL come along so sqlite can apply them locally
        img.dump(path + s, local + s)
    db = sqlite3.connect(local)
    db.execute("pragma wal_checkpoint(truncate)" if "-wal" in side else "select 1")
    db.close()
    orig = local + ".orig"
    shutil.copyfile(local, orig)
    db = sqlite3.connect(local)
    changed = False
    for table, name, value in edits:
        if is_lock:
            cur = db.execute("select value from locksettings where name=? and user=0", (name,)).fetchone()
            if cur is None or cur[0] != value:
                db.execute("delete from locksettings where name=? and user=0", (name,))
                db.execute("insert into locksettings (name,user,value) values (?,0,?)", (name, value))
                changed = True
        else:
            cur = db.execute(f"select value from {table} where name=?", (name,)).fetchone()
            if cur is None:
                db.execute(f"insert into {table} (name,value) values (?,?)", (name, value))
                changed = True
            elif cur[0] != value:
                db.execute(f"update {table} set value=? where name=?", (value, name))
                changed = True
        print(f"   {os.path.basename(path)} {table}.{name} = {value}"
              + ("" if changed else " (already)"))
    db.commit()
    db.close()
    if changed:
        mode, uid, gid = img.attrs(path)
        img.backup_once(path, orig, is_file=True)
        img.put(local, path, "010" + mode.lstrip("0").rjust(4, "0"), uid, gid)
        for s in ("-journal", "-wal", "-shm"):  # those are folded in locally now, stale copies on the image would be plain wrong
            img.rm(path + s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="work/raw/p6.img")
    ap.add_argument("--apps", default="work/apps")
    ap.add_argument("--config", default="config")
    ap.add_argument("--system", default="work/system")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    img = Img(a.data, a.dry_run)
    if not img.exists("/app") or not img.exists(PKGS) or not img.exists(RESTR):
        sys.exit(f"{a.data} doesnt look like the panels /data partition")
    state = json.loads(img.cat(STATE) or "{}") if img.exists(STATE) else {}
    if not state and img.exists(OLD_STATE):
        state = {"packages": img.cat(OLD_STATE).split()}

    # 1) APKs
    pkgs_xml = img.cat(PKGS)
    pkgs_new = pkgs_xml
    for fn in sorted(os.listdir(a.apps)) if os.path.isdir(a.apps) else []:
        if not fn.endswith(".apk"):
            continue
        pkg, d = fn[:-4], f"/app/{fn[:-4]}-1"
        m = pkg_block(pkgs_new, pkg)
        is_system = bool(m and re.search(r'codePath="/system/', m.group(0))) or \
            bool(re.search(r'<updated-package name="%s"' % re.escape(pkg), pkgs_new))
        print(f">> {'update system app' if is_system else 'install'} {pkg} -> /data{d}/base.apk")
        img.mkdir(d, "040755")
        img.put(os.path.abspath(os.path.join(a.apps, fn)), f"{d}/base.apk", "0100644")
        if is_system:
            pkgs_new, changed = as_system_update(pkgs_new, pkg, f"/data{d}")
            if changed:
                print(f"   packages.xml: {pkg} registered as updated system app")
    if pkgs_new != pkgs_xml:
        img.backup_once(PKGS, pkgs_xml)
        img.put_text(pkgs_new, PKGS)

    # 2) package-restrictions.xml
    pkgs = set(read_list(os.path.join(a.config, "disable-packages.txt")))
    comps = set(read_list(os.path.join(a.config, "disable-components.txt")))
    xml = img.cat(RESTR)
    new = xml
    for p in sorted(pkgs | set(state.get("packages", []))):
        print(f">> {'disable' if p in pkgs else 're-enable'} {p}")
        new = set_pkg_enabled(new, p, p in pkgs)
    required = set(read_list(os.path.join(a.config, "required-packages.txt")))
    for p in sorted(required):
        m = pkg_entry(new, p)
        if m and re.search(r'enabled="[23]"', m.group(0)):
            print(f">> re-enable required package {p}")
            new = set_pkg_enabled(new, p, False)
    for c in sorted(comps | set(state.get("components", []))):
        pkg, cls = c.split("/", 1)
        cls = pkg + cls if cls.startswith(".") else cls
        known = bool(pkg_block(pkgs_new, pkg))
        print(f">> {'disable' if c in comps else 're-enable'} component {pkg}/{cls}"
              + ("" if known else "  (!! package not registered yet, Android will drop this)"))
        new = set_component_disabled(new, pkg, cls, c in comps)
    if new != xml:
        img.backup_once(RESTR, xml)
        img.put_text(new, RESTR)

    # 3) side buttons
    buttons = os.path.join(a.config, "input/buttons.kl")
    if os.path.exists(buttons):
        kl, idc = build_input(a.system, buttons)
        print(f">> side buttons: /data{DEV_DIR}/keylayout/{KL_NAME}.kl + idc/Vendor_0001_Product_0001.idc")
        for d in (DEV_DIR, f"{DEV_DIR}/keylayout", f"{DEV_DIR}/idc"):
            img.mkdir(d)
        img.put_text(kl, f"{DEV_DIR}/keylayout/{KL_NAME}.kl", "0100644")
        img.put_text(idc, f"{DEV_DIR}/idc/Vendor_0001_Product_0001.idc", "0100644")
        img.rm(f"{DEV_DIR}/keylayout/ft5x06.kl")  # leftover of an earlier attempt that did nothing

    # Chromium: keep its profile.
    # crestInit.sh wipes /data/data/org.chromium.chrome and mounts a tmpfs over it at every boot unless persist.sys.app.browser_cache=true.
    # it also created the folder for uid 10002 (Crestrons old browser), so we hand it to Chromiums real uid.
    if img.exists("/property"):
        print(">> Chromium: profile kept across reboots (persist.sys.app.browser_cache=true)")
        local = os.path.join(img.tmp, "browser_cache")
        open(local, "w").write("true")
        img.put(local, "/property/persist.sys.app.browser_cache", "0100600", "0", "0")
        m = re.search(r'<package name="org\.chromium\.chrome"[^>]*userId="(\d+)"', img.cat(PKGS))
        if m and img.exists("/data/org.chromium.chrome"):
            img.owned("/data/org.chromium.chrome", "040751", m.group(1), m.group(1))
            print(f"   /data/data/org.chromium.chrome -> uid {m.group(1)}")

    # ssh keys for Dropbear (crusty-boot.sh from the eMMC update starts it)
    keys = os.path.join(a.config, "ssh", "authorized_keys")
    if os.path.exists(keys) and open(keys).read().strip():
        n = sum(1 for l in open(keys) if l.strip() and not l.startswith("#"))
        print(f">> ssh: {n} key(s) -> /data/crusty/ssh/authorized_keys")
        img.mkdir("/crusty", "040775")
        if not img.exists("/crusty/ssh"):
            img.cmds.append("mkdir /crusty/ssh")
        img.owned("/crusty/ssh", "040700", "0", "0")
        img.put(keys, "/crusty/ssh/authorized_keys", "0100600", "0", "0")

    # wallpaper: something stores Launcher2's default_wallpaper resource as the wallpaper, which is a 332 byte XML and not an image so Android falls back to the default anyway.
    # we clear it so the system default (branding/wallpaper.jpg, see tools/build-emmc.py) is whats set.
    # a wallpaper somebody picked themselves is left alone.
    wp_info = "/system/users/0/wallpaper_info.xml"
    if img.exists(wp_info) and "res:com.android.launcher:" in img.cat(wp_info):
        print(">> wallpaper: Launcher2's default removed (the system default shows instead)")
        img.rm(wp_info)
        img.rm("/system/users/0/wallpaper")

    # 4) settings
    ini = os.path.join(a.config, "settings.ini")
    if os.path.exists(ini):
        cp = configparser.ConfigParser(delimiters=("=",), comment_prefixes=("#",))
        cp.optionxform = str
        cp.read(ini)
        normal = [(s, k, v) for s in cp.sections() if s in ("secure", "global", "system") for k, v in cp[s].items()]
        lock = [("locksettings", k, v) for k, v in cp["locksettings"].items()] if "locksettings" in cp else []
        print(">> settings")
        if normal:
            edit_sqlite(img, SETTINGS_DB, normal, False)
        if lock:
            edit_sqlite(img, LOCK_DB, lock, True)

    img.put_text(json.dumps({"packages": sorted(pkgs), "components": sorted(comps)}, indent=1) + "\n", STATE)
    img.rm(OLD_STATE)
    img.commit()
    if a.dry_run:
        if pkgs_new != pkgs_xml:
            import difflib
            print("".join(difflib.unified_diff(pkgs_xml.splitlines(True), pkgs_new.splitlines(True), n=1)))
        if new != xml:
            import difflib
            print("".join(difflib.unified_diff(xml.splitlines(True), new.splitlines(True), n=1)))
    else:
        print("done, now run tools/pack.sh to build the card image.")


if __name__ == "__main__":
    main()
