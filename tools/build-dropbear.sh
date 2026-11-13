#!/usr/bin/env bash
# builds Dropbear (MIT, https://matt.ucc.asn.au/dropbear/) as a static ARMv7 binary for the panel, an SSH server with key-only logins that crusty-boot.sh starts.
# crestrons own sshd is tied to crestrons user database and only gives you the crestron console (bs), so we bring our own.
# needs tools/build-su.sh first because thats who fetches the NDK, other than that rerun whenever, it builds from a fresh unpack every time.
#
#   tools/build-dropbear.sh [work/]     -> work/dropbear/dropbearmulti  (dropbear, dropbearkey, scp)
set -euo pipefail
WORK=$(realpath -m "${1:-work}")
C="$WORK/.cache"
V=2026.94
SHA256=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
OUT="$WORK/dropbear"
NDK="$C/android-ndk-r25c"
[ -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ] || { echo "run tools/build-su.sh first (it fetches the NDK)" >&2; exit 1; }
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
mkdir -p "$C" "$OUT"

T="$C/dropbear-$V.tar.bz2"
[ -f "$T" ] || curl -fsSL -o "$T" "https://matt.ucc.asn.au/dropbear/releases/dropbear-$V.tar.bz2"
echo "$SHA256  $T" | sha256sum -c --quiet
B="$C/build/dropbear"
rm -rf "$B"; mkdir -p "$B"
tar xjf "$T" -C "$B" --strip-components=1

# the compat getusershell() (from OpenBSD) calls fgets() with size 0 on its last round, once the whole file is read.
# glibc just returns NULL, Bionics FORTIFY aborts instead ("fgets: buffer size 0 <= 0") and that killed every single login, very prem.
# so we stop when theres no room left (the buffer is st_size + 1).
grep -q 'while (fgets(cp, flen - (cp - strings), fp) != NULL)' "$B/src/compat.c"
sed -i 's/while (fgets(cp, flen - (cp - strings), fp) != NULL)/while (flen + 1 - (cp - strings) > 1 \&\& fgets(cp, flen + 1 - (cp - strings), fp) != NULL)/' "$B/src/compat.c"

# the NDKs libc.a is todays Bionic, so getpwnam() says roots shell is /bin/sh (Android 10+ has a /bin symlink).
# Lollipop has no /bin so we use /system/bin/sh when the reported shell isnt there.
grep -q 'ses.authstate.pw_shell = m_strdup(pw->pw_shell);' "$B/src/common-session.c"
sed -i 's|ses.authstate.pw_shell = m_strdup(pw->pw_shell);|ses.authstate.pw_shell = m_strdup((pw->pw_shell \&\& access(pw->pw_shell, X_OK) == 0) ? pw->pw_shell : "/system/bin/sh");|' "$B/src/common-session.c"

cat > "$B/localoptions.h" <<'EOF'
/* crusty: keys only (Android has no password database), Android paths */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_X11FWD 0
/* Android has no /etc/shells; root's shell from Bionic's getpwnam() is /system/bin/sh */
#define COMPAT_USER_SHELLS "/system/bin/sh","/system/bin/bash"
#define DEFAULT_PATH "/sbin:/system/bin:/system/xbin"
#define DEFAULT_ROOT_PATH "/sbin:/system/bin:/system/xbin"
#define SFTPSERVER_PATH "/system/bin/sftp-server"
#define DROPBEAR_PIDFILE "/data/crusty/ssh/dropbear.pid"
#define DSS_PRIV_FILENAME "/data/crusty/ssh/host_dss"
#define RSA_PRIV_FILENAME "/data/crusty/ssh/host_rsa"
#define ECDSA_PRIV_FILENAME "/data/crusty/ssh/host_ecdsa"
#define ED25519_PRIV_FILENAME "/data/crusty/ssh/host_ed25519"
EOF
# Bionic wants PT_TLS aligned to 32 on ARM, the whole sad story is in tools/build-su.sh
cat > "$B/tls_align.c" <<'EOF'
__asm__(".section .tbss.crusty_tls_align,\"awT\",%nobits\n.balign 32\n.zero 32\n.previous\n");
EOF

cd "$B"
export CC="$BIN/clang --target=armv7a-linux-androideabi21" AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" STRIP="$BIN/llvm-strip"
./configure --host=arm-linux-androideabi --enable-static --disable-zlib --disable-harden \
    --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
    --disable-pututline --disable-pututxline --disable-loginfunc --disable-syslog > build.log 2>&1
# configure cant look at the targets /dev when cross-compiling so we tell it to use /dev/ptmx, Android has it and Bionic has grantpt/unlockpt/ptsname.
# otherwise we'd get the BSD /dev/ptyXX fallback which is no bueno here.
echo '#define USE_DEV_PTMX 1' >> config.h
echo ">> dropbear $V (NDK r25c clang, static, armeabi-v7a, API 21), log: $B/build.log"
make -j"$(nproc)" PROGRAMS="dropbear dropbearkey scp" MULTI=1 STATIC=1 \
    LIBS="$B/tls_align.c" >> build.log 2>&1 || { tail -30 build.log; exit 1; }
"$STRIP" dropbearmulti
cp dropbearmulti "$OUT/"
"$BIN/llvm-readelf" -lW "$OUT/dropbearmulti" | awk '$1=="TLS"{print "   TLS segment align " $NF; if (strtonum($NF) < 32) {print "!! TLS underaligned"; exit 1}}'
file "$OUT/dropbearmulti"
ls -l "$OUT/dropbearmulti"
