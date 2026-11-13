#!/usr/bin/env bash
# builds the APKs that tools/mod-data.py yeets onto the panels /data.
# needs tools/extract.sh to have run first because we steal the panels SystemUI + framework, other than that rerun whenever.
#
#   tools/build-apps.sh [work/]        (NAVBAR=0 to skip the forced soft nav bar)
#
# com.android.settings / com.android.launcher are AOSP 5.1.1 Settings and Launcher2 out of googles API 22 ARM emulator image (test-keys).
# they are odexed in there (because of course they are) so its oat2dex -> baksmali -> patches -> smali.
# com.android.systemui is the panels *own* SystemUI, patched to use the phone status bar (+ nav bar) instead of the empty TV one, it goes in as an update of the system app.
# everything gets signed with the public AOSP platform key which also happens to be the panels platform key (sha256 C8:A2:E9:BC:...:2A:B8), so they run as platform apps lol.
# output lands in work/apps/<package>.apk, downloads are cached in work/.cache so we dont download half of google every time.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(realpath -m "${1:-work}")
NAVBAR=${NAVBAR:-1}
C="$WORK/.cache"
OUT="$WORK/apps"
mkdir -p "$C" "$OUT"
[ -f "$WORK/system/priv-app/SystemUI/SystemUI.apk" ] || { echo "run tools/extract.sh first" >&2; exit 1; }

fetch() {  # url file sha256
    if [ ! -f "$C/$2" ] || ! echo "$3  $C/$2" | sha256sum -c --quiet - 2>/dev/null; then
        echo ">> downloading $2"
        curl -sSfL -o "$C/$2.part" "$1"
        echo "$3  $C/$2.part" | sha256sum -c --quiet - || { echo "!! checksum of $2 is wrong, not using that" >&2; exit 1; }
        mv "$C/$2.part" "$C/$2"
    fi
}

fetch https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-22_r02.zip \
      sysimg-22-armv7.zip 5d8fd19b18ae70859b9c826b7c642ffe4f728ce253e5f91c883bdb912f3582d4
fetch https://dl.google.com/android/repository/build-tools_r34-linux.zip \
      build-tools-34.zip e858c4b60069d0431051b225d384413b1643e1289b00a4825aed347f25bd510f
fetch https://github.com/testwhat/SmaliEx/releases/download/0.86/oat2dex.jar \
      oat2dex.jar 4b503557b34ddf29cabb375cec5ddaef0c3f5989c7bbbd24bf3b1abe668224a1
fetch https://bitbucket.org/JesusFreke/smali/downloads/baksmali-2.5.2.jar \
      baksmali-2.5.2.jar d3116248cce4f82ec5a31eb7f95ee75daff42ddf6eed0ab573973dc53fbad2e5
fetch https://bitbucket.org/JesusFreke/smali/downloads/smali-2.5.2.jar \
      smali-2.5.2.jar 9544299578b16f771d8aa8eaefe0d3718ca03478c16f3c356f2fcf1366bfb116
# for our own app (app/companion): Android 5.1 SDK + the eclipse java compiler, which runs on a plain JRE
fetch https://dl.google.com/android/repository/android-22_r02.zip \
      android-22_r02.zip 45eb581bbe53c9256f34c26b2cea919543c0079140897ac721cf88c0b9f6789e
fetch https://repo1.maven.org/maven2/org/eclipse/jdt/ecj/3.38.0/ecj-3.38.0.jar \
      ecj-3.38.0.jar 97c566b120009c203a2fc8b291f4a9adbc171cf1ccb70f06f6b4e1828c00ce8e
[ -f "$C/platform-22/android.jar" ] || 7z e -y -o"$C/platform-22" "$C/android-22_r02.zip" '*/android.jar' >/dev/null
AOSP=https://android.googlesource.com/platform/build/+/refs/tags/android-5.1.1_r6/target/product/security
for f in platform.pk8 platform.x509.pem; do
    [ -s "$C/$f" ] || curl -sSf "$AOSP/$f?format=TEXT" | base64 -d > "$C/$f"
done
fp=$(openssl x509 -in "$C/platform.x509.pem" -noout -fingerprint -sha256 | cut -d= -f2)
[ "$fp" = "C8:A2:E9:BC:CF:59:7C:2F:B6:DC:66:BE:E2:93:FC:13:F2:FC:47:EC:77:BC:6B:2B:0D:52:C1:1F:51:19:2A:B8" ] \
    || { echo "!! thats not the AOSP platform key, fingerprint is $fp" >&2; exit 1; }

BT="$C/android-14"
[ -x "$BT/apksigner" ] || (cd "$C" && 7z x -y build-tools-34.zip >/dev/null)
baksmali() { java -jar "$C/baksmali-2.5.2.jar" "$@" 2>&1 | grep -v WARNING || true; }
smali()    { java -jar "$C/smali-2.5.2.jar" "$@"; }

T="$C/sysimg"
if [ ! -f "$T/system.img" ]; then
    mkdir -p "$T"
    7z e -y -o"$T" "$C/sysimg-22-armv7.zip" armeabi-v7a/system.img >/dev/null
fi

B="$C/bootdex"
if [ ! -d "$B/odex" ]; then
    echo ">> deoptimizing emulator boot.oat"
    rm -rf "$B"; mkdir -p "$B"
    debugfs -R "dump /framework/arm/boot.oat $B/boot.oat" "$T/system.img" 2>/dev/null
    (cd "$B" && java -jar "$C/oat2dex.jar" boot boot.oat >/dev/null)
fi

# framework-res IDs that moved between the emulator and the panel, patches.py needs them for remapping
MAP="$C/fwres-remap.txt"
if [ ! -s "$MAP" ]; then
    debugfs -R "dump /framework/framework-res.apk $C/emu-framework-res.apk" "$T/system.img" 2>/dev/null
    ids() { "$BT/aapt" dump resources "$1" | sed -nE 's/^\s+spec resource (0x[0-9a-f]+) android:([^:]+):.*/\1 \2/p' | sort -k2; }
    join -1 2 -2 2 <(ids "$C/emu-framework-res.apk") <(ids "$WORK/system/framework/framework-res.apk") \
        | awk '$2!=$3{print $2, $3, $1}' > "$MAP"
fi

finish() {  # src-apk dex-dir tmp  -> signed apk in $OUT
    local src=$1 dexdir=$2 tmp=$3
    python3 - "$src" "$dexdir" "$tmp/unsigned.apk" <<'EOF'
import os, sys, zipfile
src, dexdir, out = sys.argv[1:]
dexes = sorted(f for f in os.listdir(dexdir) if f.endswith(".dex"))
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w") as zo:
    for i in zi.infolist():
        n = i.filename
        if n.startswith("META-INF/") or (n.startswith("classes") and n.endswith(".dex")):
            continue  # old signature / old code, replaced below
        zo.writestr(i, zi.read(n))
    for d in dexes:
        zo.write(os.path.join(dexdir, d), d, compress_type=zipfile.ZIP_DEFLATED)
EOF
    "$BT/zipalign" -f -p 4 "$tmp/unsigned.apk" "$tmp/aligned.apk"
    local pkg
    pkg=$("$BT/aapt2" dump packagename "$tmp/aligned.apk")
    "$BT/apksigner" sign --key "$C/platform.pk8" --cert "$C/platform.x509.pem" \
        --min-sdk-version 22 --v4-signing-enabled false --out "$OUT/$pkg.apk" "$tmp/aligned.apk" 2>/dev/null
    "$BT/apksigner" verify --min-sdk-version 22 "$OUT/$pkg.apk" 2>/dev/null
    echo "   -> $OUT/$pkg.apk"
}

build_emu() {  # path-in-emulator-image name
    local dir=$1 name=$2 tmp="$C/build/$2"
    echo ">> $name (AOSP, from emulator image)"
    rm -rf "$tmp"; mkdir -p "$tmp/dex"
    debugfs -R "dump $dir/$name.apk $tmp/$name.apk" "$T/system.img" 2>/dev/null
    debugfs -R "dump $dir/arm/$name.odex $tmp/$name.odex" "$T/system.img" 2>/dev/null
    (cd "$tmp" && java -jar "$C/oat2dex.jar" "$name.odex" "$B/odex" >/dev/null)
    baksmali d -a 22 "$tmp/$name.dex" -o "$tmp/smali"
    python3 "$HERE/patches.py" "$name" "$tmp/smali" --fwres-map "$MAP"
    smali a -a 22 "$tmp/smali" -o "$tmp/dex/classes.dex"
    local src="$tmp/$name.apk"
    if [ "$name" = Settings ]; then
        # the encryption screen (CryptKeeper) is a HOME activity with priority 10 and it only disables itself once it has run.
        # so on a fresh flash android pops a "choose home app" dialog, no bueno.
        # the panel isnt encrypted anyway so its HOME category goes bye bye.
        python3 "$HERE/axml.py" drop-home "$src" "$tmp/manifest.apk" com.android.settings.CryptKeeper
        src="$tmp/manifest.apk"
    fi
    finish "$src" "$tmp/dex" "$tmp"
}

java_to_dex() {  # src-dir out-dex-dir tmp   (Java 8 sources against the API 22 android.jar)
    local AJ="$C/platform-22/android.jar"
    rm -rf "$3"; mkdir -p "$3" "$2"
    # ECJ (pinned, runs on a plain JRE) and not javac, because d8 from build-tools 34 crashes with an NPE on class files from javac 25, even with -source/-target 8 (what a shocker i know).
    java -jar "$C/ecj-3.38.0.jar" -source 1.8 -target 1.8 -nowarn -bootclasspath "$AJ" \
        -d "$3" $(find "$1" -name '*.java')
    "$BT/d8" --min-api 22 --lib "$AJ" --output "$2" $(find "$3" -name '*.class')
}

build_system_app() {  # name path-in-panel-system inject-dir [patch args...]
    # patches one of the panels own system apps, gets installed as a system-app update on /data
    local name=$1 src="$WORK/system/$2" inject=$3 tmp="$C/build/$1"; shift 3
    echo ">> $name (panel's own, patched)"
    rm -rf "$tmp"; mkdir -p "$tmp/dex"
    # our helper classes go to smali and get merged into the apps classes.dex
    java_to_dex "$inject" "$tmp/inject-dex" "$tmp/inject-classes"
    baksmali d -a 22 "$tmp/inject-dex/classes.dex" -o "$tmp/inject-smali"
    for d in $(7z l "$src" | grep -oE 'classes[0-9]*\.dex' | sort -u); do
        baksmali d -a 22 "$src/$d" -o "$tmp/smali_$d"
        if [ "$d" = classes.dex ]; then
            cp -r "$tmp/inject-smali/." "$tmp/smali_$d/"
            python3 "$HERE/patches.py" "$name" "$tmp/smali_$d" "$@"
        fi
        smali a -a 22 "$tmp/smali_$d" -o "$tmp/dex/$d"
    done
    finish "$src" "$tmp/dex" "$tmp"
}

build_systemui() {
    build_system_app SystemUI priv-app/SystemUI/SystemUI.apk "$HERE/../app/systemui-inject/src" --navbar "$NAVBAR"
}

build_companion() {  # our own app, from source
    local src="$HERE/../app/companion" tmp="$C/build/companion" AJ="$C/platform-22/android.jar"
    echo ">> crusty companion (app/companion)"
    rm -rf "$tmp"; mkdir -p "$tmp/res"
    "$BT/aapt2" compile --dir "$src/res" -o "$tmp/res.zip"
    "$BT/aapt2" link -o "$tmp/base.apk" --manifest "$src/AndroidManifest.xml" -I "$AJ" \
        -R "$tmp/res.zip" --min-sdk-version 22 --target-sdk-version 22
    java_to_dex "$src/src" "$tmp/dex" "$tmp/classes"
    finish "$tmp/base.apk" "$tmp/dex" "$tmp"
}

rm -f "$OUT"/*.apk
build_companion
build_emu /priv-app/Settings Settings
build_emu /priv-app/Launcher2 Launcher2
build_systemui
build_system_app AppInstaller app/AppInstaller/AppInstaller.apk "$HERE/../app/appinstaller-inject/src"
