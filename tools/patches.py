#!/usr/bin/env python3
"""the smali patches for the panels apps, tools/build-apps.sh runs this (and tools/build-emmc.py does for policy).

  patches.py <app> <smali-dir> [options]

every patch checks that it matched exactly as expected, so a different firmware or app version blows up loudly right here instead of giving us a silently broken APK.
"""
import argparse
import os
import re
import sys


def edit(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    if n != count:
        sys.exit(f"patch failed: expected {count}x {old!r} in {path}, found {n}")
    open(path, "w").write(s.replace(old, new))
    print(f"   patched {os.path.basename(path)}")


def remap_framework_ids(root, mapfile):
    """rewrites framework internal resource IDs that differ between the emulator framework the app was built against and the panels framework-res, Amlogic stuffed extra resources in there and that shifted some of the private IDs"""
    remap = {}
    for line in open(mapfile):
        old, new, name = line.split()
        remap["0x" + old[2:].lstrip("0")] = ("0x" + new[2:].lstrip("0"), name)
    pat = re.compile(r"\b(0x1[0-9a-f]{6})\b")
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            s = open(p).read()
            if not any(k in s for k in remap):
                continue
            hits = []

            def sub(m):
                if m.group(1) in remap:
                    hits.append(remap[m.group(1)][1])
                    return remap[m.group(1)][0]
                return m.group(1)
            out = "\n".join(pat.sub(sub, l) if l.lstrip().startswith("const") else l
                            for l in s.split("\n"))
            if hits:
                open(p, "w").write(out)
                print(f"   remapped {', '.join(sorted(set(hits)))} in {f}")


def settings(root, a):
    # Build.VERSION.SECURITY_PATCH only exists in later 5.1.1 builds (LMY48+), the panel is LMY47V so opening "About" dies with a NoSuchFieldError.
    # we hand it an empty string instead, the code already deals with that by hiding the entry.
    edit(f"{root}/com/android/settings/DeviceInfoSettings.smali",
         "sget-object v3, Landroid/os/Build$VERSION;->SECURITY_PATCH:Ljava/lang/String;",
         'const-string v3, ""')
    # no telephony on the panel (what a shocker i know) so Status > "IMEI information" crashes ("Default phones haven't been made yet").
    # stock code only removes IMEI + SIM status for secondary users, we do it always.
    edit(f"{root}/com/android/settings/deviceinfo/Status.smali",
         "invoke-static {}, Landroid/os/UserHandle;->myUserId()I\n\n    move-result v5\n\n"
         "    if-eqz v5, :cond_d6\n\n    .line",
         "invoke-static {}, Landroid/os/UserHandle;->myUserId()I\n\n    move-result v5\n\n"
         "    # crusty: always remove sim_status + imei_info (no phone)\n\n    .line")
    remap_framework_ids(root, a.fwres_map)


def appinstaller(root, a):
    if not os.path.exists(f"{root}/com/droidlogic/appinstall/CrustyFix.smali"):
        sys.exit("patch failed: injected CrustyFix.smali missing")
    edit(f"{root}/com/droidlogic/appinstall/main.smali",
         "    move-object/from16 v0, p0\n\n"
         "    iget-object v0, v0, Lcom/droidlogic/appinstall/main;->mDevStrs:[Ljava/lang/String;\n\n"
         "    move-object/from16 v28, v0\n\n"
         "    new-instance v29, Lcom/droidlogic/appinstall/main$7;\n",
         "    # crusty: replace null device labels before they reach the ArrayAdapter\n"
         "    invoke-static/range {p0 .. p0}, Lcom/droidlogic/appinstall/CrustyFix;->fixDevStrs(Ljava/lang/Object;)V\n\n"
         "    move-object/from16 v0, p0\n\n"
         "    iget-object v0, v0, Lcom/droidlogic/appinstall/main;->mDevStrs:[Ljava/lang/String;\n\n"
         "    move-object/from16 v28, v0\n\n"
         "    new-instance v29, Lcom/droidlogic/appinstall/main$7;\n")


def policy(root, a):
    """android.policy.jar (eMMC /system/framework): the panels PhoneWindowManager sets mKeyguardDelegate = null in systemReady() (no keyguard at all), but launchHomeFromHotKey() calls mKeyguardDelegate.isInputRestricted() without a null check.
    so every HOME press throws a NullPointerException and gets dropped, premium engineering right there.
    we treat null as "not restricted" and jump to the normal go-home path, :cond_1e."""
    path = f"{root}/com/android/internal/policy/impl/PhoneWindowManager.smali"
    s = open(path).read()
    a0 = s.index(".method launchHomeFromHotKey()V")
    a1 = s.index(".end method", a0)
    body = s[a0:a1]
    old = ("    iget-object v0, p0, Lcom/android/internal/policy/impl/PhoneWindowManager;->mKeyguardDelegate:"
           "Lcom/android/internal/policy/impl/keyguard/KeyguardServiceDelegate;\n\n"
           "    invoke-virtual {v0}, Lcom/android/internal/policy/impl/keyguard/KeyguardServiceDelegate;->isInputRestricted()Z\n")
    if body.count(old) != 1 or ":cond_1e" not in body:
        sys.exit("patch failed: launchHomeFromHotKey() doesnt look like we expected")
    new = old.replace("\n\n    invoke-virtual",
                      "\n\n    # crusty: no keyguard on this panel -> don't NPE\n    if-eqz v0, :cond_1e\n\n    invoke-virtual", 1)
    open(path, "w").write(s[:a0] + body.replace(old, new, 1) + s[a1:])
    print("   patched PhoneWindowManager.launchHomeFromHotKey (null keyguard)")


def launcher2(root, a):
    remap_framework_ids(root, a.fwres_map)


TV_STATUS_BAR = """.class public Lcom/android/systemui/statusbar/tv/TvStatusBar;
.super Lcom/android/systemui/statusbar/phone/PhoneStatusBar;
.source "TvStatusBar.java"

# crusty: the panel's SystemUI is configured (config_statusBarComponent) to use
# the empty Android-TV status bar. Turn that class into the regular phone status
# bar so we get status bar, notification shade and quick settings.

.method public constructor <init>()V
    .registers 1
    invoke-direct {p0}, Lcom/android/systemui/statusbar/phone/PhoneStatusBar;-><init>()V
    return-void
.end method
"""


def systemui(root, a):
    p = f"{root}/com/android/systemui/statusbar/tv/TvStatusBar.smali"
    if ".super Lcom/android/systemui/statusbar/BaseStatusBar;" not in open(p).read():
        sys.exit("patch failed: TvStatusBar isnt the BaseStatusBar subclass we expected")
    open(p, "w").write(TV_STATUS_BAR)
    print("   patched TvStatusBar.smali -> PhoneStatusBar")
    # nav bar Home: the panels PhoneWindowManager sets mKeyguardDelegate = null, so an injected KEYCODE_HOME crashes in launchHomeFromHotKey() (NPE) and does nothing.
    # so the Home button (KeyButtonView with mCode == KEYCODE_HOME) starts the home activity itself on release, via the injected helper app/systemui-inject/.../CrustyHome.java.
    if not os.path.exists(f"{root}/com/android/systemui/crusty/CrustyHome.smali"):
        sys.exit("patch failed: injected CrustyHome.smali missing")
    edit(f"{root}/com/android/systemui/statusbar/policy/KeyButtonView.smali",
         ".method sendEvent(IIJ)V\n    .registers 22\n    .param p1, \"action\"    # I\n"
         "    .param p2, \"flags\"    # I\n    .param p3, \"when\"    # J\n\n    .prologue\n",
         ".method sendEvent(IIJ)V\n    .registers 22\n    .param p1, \"action\"    # I\n"
         "    .param p2, \"flags\"    # I\n    .param p3, \"when\"    # J\n\n    .prologue\n"
         "    # crusty: Home -> start home activity directly (KEYCODE_HOME crashes in PWM here)\n"
         "    move-object/from16 v4, p0\n"
         "    iget v2, v4, Lcom/android/systemui/statusbar/policy/KeyButtonView;->mCode:I\n"
         "    const/4 v3, 0x3\n"
         "    if-ne v2, v3, :crusty_not_home\n"
         "    move/from16 v2, p1\n"
         "    const/4 v3, 0x1\n"
         "    if-ne v2, v3, :crusty_home_done\n"
         "    move/from16 v2, p2\n"
         "    and-int/lit8 v2, v2, 0x20\n"
         "    if-nez v2, :crusty_home_done\n"
         "    invoke-virtual {v4}, Landroid/view/View;->getContext()Landroid/content/Context;\n"
         "    move-result-object v2\n"
         "    invoke-static {v2}, Lcom/android/systemui/crusty/CrustyHome;->goHome(Landroid/content/Context;)V\n"
         "    :crusty_home_done\n"
         "    return-void\n"
         "    :crusty_not_home\n")
    if a.navbar:
        # qemu.hw.mainkeys=1 in the (read only) build.prop makes the window manager say "no navigation bar".
        # we create it anyway, the window manager lays it out as soon as the window exists.
        # whether to show it comes from Settings.Global crusty_navbar (default 1) via CrustyHome.showNavBar(), so the crusty companion can toggle it.
        # v3 gets overwritten right after, so its free to use here.
        edit(f"{root}/com/android/systemui/statusbar/phone/PhoneStatusBar.smali",
             "invoke-interface {v3}, Landroid/view/IWindowManager;->hasNavigationBar()Z\n\n"
             "    move-result v23\n",
             "invoke-interface {v3}, Landroid/view/IWindowManager;->hasNavigationBar()Z\n\n"
             "    move-result v23\n\n"
             "    move-object/from16 v3, p0\n"
             "    iget-object v3, v3, Lcom/android/systemui/SystemUI;->mContext:Landroid/content/Context;\n"
             "    invoke-static {v3}, Lcom/android/systemui/crusty/CrustyHome;->showNavBar(Landroid/content/Context;)Z\n"
             "    move-result v23\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("app", choices=["Settings", "Launcher2", "SystemUI", "AppInstaller", "policy"])
    ap.add_argument("root")
    ap.add_argument("--fwres-map")
    ap.add_argument("--navbar", type=int, default=1)
    a = ap.parse_args()
    {"Settings": settings, "Launcher2": launcher2, "SystemUI": systemui,
     "AppInstaller": appinstaller, "policy": policy}[a.app](a.root, a)
