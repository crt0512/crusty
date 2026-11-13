#!/usr/bin/env bash
# builds phh's Superuser (GPL-3, https://github.com/phhusson/Superuser) for the TSW-760.
# needs tools/build-apps.sh to have run because it borrows build-tools, ECJ and android.jar from work/.cache, other than that rerun whenever.
#
#   tools/build-su.sh [work/]      -> work/su/su, work/su/me.phh.superuser.apk
#
# the su binary is static, armeabi-v7a, API 21 and gets built with the Android NDK r25c.
# the manager app (me.phh.superuser) gets built with crustys gradle-free toolchain (aapt2, ECJ, d8) because nobody wants gradle in here.
# su runs as a root daemon ("su --daemon", started by crusty-boot.sh), the `su` client talks to it and asks the manager app (REQUESTOR=me.phh.superuser) whether to hand out root.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(realpath -m "${1:-work}")
C="$WORK/.cache"
SRC="$WORK/src/Superuser"
OUT="$WORK/su"
mkdir -p "$OUT" "$WORK/src"

# ---- sources (pinned commit)
REV=9ae9705
if [ ! -d "$SRC/.git" ]; then
    git clone -q --recurse-submodules https://github.com/phhusson/Superuser.git "$SRC"
fi
git -C "$SRC" checkout -q "$REV" && git -C "$SRC" submodule update -q --init

# ---- NDK r25c, the last NDK that still targets API 21, checksum is from googles repository listing
NDK="$C/android-ndk-r25c"
if [ ! -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
    curl -sSfL -o "$C/android-ndk-r25c-linux.zip" https://dl.google.com/android/repository/android-ndk-r25c-linux.zip
    echo "53af80a1cce9144025b81c78c8cd556bff42bd0e  $C/android-ndk-r25c-linux.zip" | sha1sum -c --quiet
    (cd "$C" && unzip -q -o android-ndk-r25c-linux.zip)    # unzip, not 7z: the NDK uses symlinks
fi
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang --target=armv7a-linux-androideabi21"

# ---- su binary
J="$SRC/Superuser/jni"
B="$C/build/su"; mkdir -p "$B/shim/cutils"
cat > "$B/shim/cutils/multiuser.h" <<'EOF'
/* minimal stand-in for AOSP's <cutils/multiuser.h> (only what su uses) */
#pragma once
#include <sys/types.h>
#define MULTIUSER_APP_PER_USER_RANGE 100000
typedef uid_t userid_t;
typedef uid_t appid_t;
static inline userid_t multiuser_get_user_id(uid_t uid) { return uid / MULTIUSER_APP_PER_USER_RANGE; }
static inline appid_t multiuser_get_app_id(uid_t uid) { return uid % MULTIUSER_APP_PER_USER_RANGE; }
static inline uid_t multiuser_get_uid(userid_t user, appid_t app) { return user * MULTIUSER_APP_PER_USER_RANGE + (app % MULTIUSER_APP_PER_USER_RANGE); }
EOF
# we work on a copy of the su sources, binds.c uses GCC nested functions which clang refuses to eat so unnest.py rewrites them (daemon.c goes through it too)
rm -rf "$B/su"; cp -r "$J/su" "$B/su"
for f in binds.c daemon.c; do python3 "$HERE/su/unnest.py" "$J/su/$f" "$B/su/$f"; done
# label_file.c needs pcre and su never uses the file-labelling backend anyway (it calls setfilecon directly), so it gets a stub
cat > "$B/shim/selabel_file_stub.c" <<'EOF2'
#include <errno.h>
struct selabel_handle; struct selinux_opt;
int selabel_file_init(struct selabel_handle *rec, const struct selinux_opt *opts, unsigned nopts) {
    (void) rec; (void) opts; (void) nopts; errno = ENOSYS; return -1;
}
EOF2
# Bionic (the NDKs static libc.a) refuses to start an executable whose TLS segment is aligned < 32 on ARM ("executable's TLS segment is underaligned").
# r25c's crtbegin only pads that for API >= 29 and we are API 21, so we pad it ourselfs.
cat > "$B/shim/tls_align.c" <<'EOF3'
/* raises the PT_TLS alignment to 32 (Bionic reserves the first 8 words of the thread pointer).
 * Plain asm: below API 29 the NDK uses emulated TLS, so a __thread variable wouldn't land in PT_TLS. */
__asm__(".section .tbss.crusty_tls_align,\"awT\",%nobits\n.balign 32\n.zero 32\n.previous\n");
EOF3
# all of libselinux except android.c (AOSP-only), the makefiles lists dont cover what su needs
SELINUX_SRC=$(grep -L 'pcre.h' "$J"/libselinux/src/*.c | grep -v '/android\.c$')
echo ">> su (NDK r25c clang, static, armeabi-v7a, API 21)"
$CC -static -O2 -std=gnu11 -w \
    -DSQLITE_OMIT_LOAD_EXTENSION -DAUDITD_LOG_TAG=1003 -DREQUESTOR=\"$(cat "$SRC/Superuser/packageName")\" \
    -I"$B/shim" -I"$J/libselinux/include" -I"$J/libselinux/src" -I"$J/libsepol/include" -I"$J/sqlite3" \
    -I"$B/su" "$B"/su/su.c "$B"/su/daemon.c "$B"/su/activity.c "$B"/su/db.c "$B"/su/utils.c "$B"/su/pts.c \
    "$B"/su/hacks.c "$B"/su/binds.c "$J"/sqlite3/sqlite3.c $SELINUX_SRC "$B/shim/selabel_file_stub.c" "$B/shim/tls_align.c" \
    -o "$OUT/su"
file "$OUT/su"
# did the fix actually work? PT_TLS alignment must be >= 32 or su wont even start
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -lW "$OUT/su" | awk '$1=="TLS"{print "   TLS segment align " $NF; if (strtonum($NF) < 32) {print "!! TLS underaligned"; exit 1}}'
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$OUT/su"
ls -l "$OUT/su"

# ---- manager app (me.phh.superuser), Gradle-free: aapt2 + ECJ + d8
APP="$SRC/Superuser"; WID="$SRC/Widgets/Widgets"
AJ="$C/platform-22/android.jar"; BT="$C/android-14"
A="$C/build/superuser-app"; rm -rf "$A"; mkdir -p "$A/gen" "$A/classes" "$A/dex"
echo ">> manager app (me.phh.superuser)"
"$BT/aapt2" compile --dir "$WID/res" -o "$A/widgets.zip" --legacy
# the Allow button has filterTouchesWhenObscured, so android drops taps on it while any other apps window lies on top.
# on the panel something (a crestron overlay) always does, so Allow could never be pressed (Deny has no such flag lol).
# the 3 s countdown before Allow gets enabled stays.
cp -r "$APP/res" "$A/res"
grep -q 'filterTouchesWhenObscured="true"' "$A/res/layout/request.xml"
sed -i '/android:filterTouchesWhenObscured="true"/d' "$A/res/layout/request.xml"
"$BT/aapt2" compile --dir "$A/res" -o "$A/app.zip" --legacy
# one merged resource table (like old aapt did for library projects), R for both packages
"$BT/aapt2" link -o "$A/base.apk" -I "$AJ" --manifest "$APP/AndroidManifest.xml" \
    -R "$A/widgets.zip" -R "$A/app.zip" --auto-add-overlay \
    --rename-manifest-package "$(cat "$APP/packageName")" --custom-package com.koushikdutta.superuser \
    --extra-packages com.koushikdutta.widgets --java "$A/gen" \
    --min-sdk-version 14 --target-sdk-version 22 -A "$APP/assets"
java -jar "$C/ecj-3.38.0.jar" -source 1.8 -target 1.8 -nowarn -bootclasspath "$AJ" \
    -cp "$WID/libs/android-support-v4.jar" -d "$A/classes" \
    $(find "$APP/src" "$WID/src" "$A/gen" -name '*.java')
"$BT/d8" --min-api 21 --lib "$AJ" --output "$A/dex" $(find "$A/classes" -name '*.class') "$WID/libs/android-support-v4.jar"
python3 - "$A/base.apk" "$A/dex/classes.dex" "$A/unsigned.apk" <<'PY'
import sys, zipfile
src, dex, out = sys.argv[1:]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w") as zo:
    for i in zi.infolist():
        zo.writestr(i, zi.read(i.filename))
    zo.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
PY
"$BT/zipalign" -f -p 4 "$A/unsigned.apk" "$A/aligned.apk"
# own key, NOT the platform key, the manager app needs no priviliges
KS="$C/crusty-apps.p12"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storetype PKCS12 -storepass crusty -keypass crusty \
    -alias crusty -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=crusty apps" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:crusty --ks-key-alias crusty --min-sdk-version 21 \
    --v4-signing-enabled false --out "$OUT/me.phh.superuser.apk" "$A/aligned.apk" 2>/dev/null
"$BT/apksigner" verify --min-sdk-version 21 "$OUT/me.phh.superuser.apk" 2>/dev/null && ls -l "$OUT/me.phh.superuser.apk"
