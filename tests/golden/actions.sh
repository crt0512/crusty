#!/bin/bash
# PC side test of the golden mode script's other actions (app/golden/crestInit.sh): save logs, import ssh keys, clear apps' data, verbose boot, recovery update, shut down with "stay in golden mode".
# same fake environment as run.sh (mock busybox, directory as "USB stick"), plus mocks for setprop / fw_setenv / fw_printenv.
#   tests/golden/actions.sh [script]
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../app/golden/crestInit.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/crusty-golden-test.XXXX")
trap 'kill $pid 2>/dev/null; case "$T" in "${TMPDIR:-/tmp}"/crusty-*) rm -r "$T" ;; esac' EXIT
mkdir -p "$T/data" "$T/dev" "$T/usb" "$T/bin" "$T/appdata"
: > "$T/dev/sda1"
echo "/dev/block/vold/8:1 $T/usb vfat rw 0 0" > "$T/mounts"
printf "major minor  #blocks  name\n\n 179       16       3072 mmcblk1\n" > "$T/partitions"

printf '#!/bin/sh\necho "$@" >> %s/setprop.log\n' "$T" > "$T/bin/setprop"
printf '#!/bin/sh\n: > %s/%s\n' "$T" "touched" > "$T/bin/start"
printf '#!/bin/sh\necho "$1=$2" >> %s/env\n' "$T" > "$T/bin/fw_setenv"
printf '#!/bin/sh\ngrep "^$1=" %s/env | tail -1\n' "$T" > "$T/bin/fw_printenv"
printf '#!/bin/sh\necho logcat-mock\n' > "$T/bin/logcat"
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH"

sed -e "s|^BB=/system/bin/busybox|BB=$HERE/bb|" -e "s|^DIR=/data/crusty|DIR=$T/data/crusty|" -e "s|^USB=/mnt/crusty_usb|USB=$T/usb|" \
    -e "s|/proc/mounts|$T/mounts|g" -e "s|/proc/partitions|$T/partitions|g" -e "s|/dev/crusty_|$T/crusty_|g" \
    -e "s|/system/bin/fw_printenv|$T/bin/fw_printenv|g" -e "s|/system/bin/fw_setenv|$T/bin/fw_setenv|g" \
    -e "s|/data/data|$T/appdata|g" -e "s|/proc/sysrq-trigger|$T/sysrq|g" -e "s|sleep 20|sleep 1|" \
    -e "s|/system/bin/sh -n|sh -n|g" -e "s|/system/bin/dd|dd|g" -e "s|\[ -b |[ -e |g" -e "s|^start watchdog|: start watchdog|" -e "s|dmesg |true |" \
    -e "s|/sys/class/|$T/sys/|g" "$SRC" > "$T/golden-test.sh"
SH=$(command -v mksh || echo "busybox sh")
echo "   shell: $SH"
$SH "$T/golden-test.sh" 2>"$T/stderr.txt" & pid=$!
sleep 1

req() { echo "$1" > "$T/data/crusty/golden-request"; sleep 4; }
check() { if eval "$2"; then echo "   ok:   $1"; else echo "   FAIL: $1"; fail=1; fi; }
fail=0
LOG=$T/data/crusty/golden.log

# ssh keys: authorized_keys + a .pub on the stick, a junk line is ignored, a second import adds nothing
printf 'ssh-ed25519 AAAAone a@b\nnot a key\n' > "$T/usb/authorized_keys"
printf 'ssh-rsa AAAAtwo c@d\nssh-ed25519 AAAAone a@b\n' > "$T/usb/me.pub"
req sshkeys
check "ssh keys imported once each" '[ "$(wc -l < "$T/data/crusty/ssh/authorized_keys")" = 2 ]'
req sshkeys
check "second import adds nothing" '[ "$(wc -l < "$T/data/crusty/ssh/authorized_keys")" = 2 ] && grep -q "0 new" "$LOG"'

# clear apps' data: files go, the lib link, crusty and the providers stay
mkdir -p "$T/appdata/com.foo/files" "$T/appdata/com.foo/shared_prefs" "$T/appdata/dev.crusty.companion/shared_prefs" "$T/appdata/com.android.providers.settings/databases"
touch "$T/appdata/com.foo/files/x" "$T/appdata/com.foo/.hidden" "$T/appdata/dev.crusty.companion/shared_prefs/p.xml" "$T/appdata/com.android.providers.settings/databases/settings.db"
ln -s /nonexistent "$T/appdata/com.foo/lib"
req cleardata
check "app data cleared" '[ ! -e "$T/appdata/com.foo/files" ] && [ ! -e "$T/appdata/com.foo/.hidden" ] && [ ! -e "$T/appdata/com.foo/shared_prefs" ]'
check "lib link, crusty and settings.db kept" '[ -L "$T/appdata/com.foo/lib" ] && [ -e "$T/appdata/dev.crusty.companion/shared_prefs/p.xml" ] && [ -e "$T/appdata/com.android.providers.settings/databases/settings.db" ]'

# save logs: the folder is named after the MAC (the clock is 1970 in golden mode), a second save gets -2
echo 'ethaddr=00:10:7f:b9:c8:87' > "$T/env"
req savelogs
check "logs on the stick, named after the MAC" '[ -s "$T/usb/crusty-logs-00107FB9C887/golden.log" ] && [ -s "$T/usb/crusty-logs-00107FB9C887/logcat.txt" ]'
req savelogs
check "second save gets -2" '[ -s "$T/usb/crusty-logs-00107FB9C887-2/golden.log" ]'

# verbose boot: swaps the ${bootargs_console} word in initargs for a real console and back, the flag file follows
echo 'initargs=rootfstype=ramfs init=/init ${bootargs_console} no_console_suspend earlyprintk storage=2' > "$T/env"
req verboseon
check "verbose on: console in initargs" 'grep -q "^initargs=.* console=ttyS0,115200n8 ignore_loglevel no_console_suspend" "$T/env" && ! tail -1 "$T/env" | grep -q bootargs_console'
check "verbose flag set" '[ -f "$T/data/crusty/golden-verbose" ]'
req verboseon
check "verbose on twice changes nothing" '[ "$(grep -c "^initargs=" "$T/env")" = 2 ]'
req verboseoff
check "verbose off: back to the original" 'tail -1 "$T/env" | grep -qF "init=/init \${bootargs_console} no_console_suspend earlyprintk storage=2" && [ ! -f "$T/data/crusty/golden-verbose" ]'

# verbose boot on screen: just the flag file the app looks for
req verbosescreenon
check "screen flag set" '[ -f "$T/data/crusty/config/verbose_screen" ]'
req verbosescreenoff
check "screen flag removed" '[ ! -e "$T/data/crusty/config/verbose_screen" ]'

# update the recovery from the stick: installs what the MANIFEST lists (md5 checked, .new renamed over the old file), refuses damaged files and shell scripts with syntax errors without touching anything
RD=$T/usb/crusty-recovery-update; mkdir -p "$RD" "$T/fake/bin" "$T/fake/app"
md5() { md5sum "$1" | cut -d' ' -f1; }
manifest() { printf '%s new.sh %s 0755 0:0\n%s app.apk %s 0644 0:0\n' "$T/fake/bin/x.sh" "$(md5 "$RD/new.sh")" "$T/fake/app/base.apk" "$(md5 "$RD/app.apk")" > "$RD/MANIFEST"; }
echo 'echo old' > "$T/fake/bin/x.sh"; echo oldapk > "$T/fake/app/base.apk"
echo 'echo new' > "$RD/new.sh"; echo newapk > "$RD/app.apk"; manifest
req recovery
check "recovery files replaced" 'cmp -s "$RD/new.sh" "$T/fake/bin/x.sh" && cmp -s "$RD/app.apk" "$T/fake/app/base.apk" && [ -x "$T/fake/bin/x.sh" ]'
check "no .new leftovers" '! ls "$T"/fake/*/*.new >/dev/null 2>&1'
echo 'echo old' > "$T/fake/bin/x.sh"; echo 'echo broken (' > "$RD/new.sh"; manifest
req recovery
check "syntax error in a script: nothing replaced" 'grep -qx "echo old" "$T/fake/bin/x.sh" && grep -q "syntax error" "$LOG"'
echo 'echo new' > "$RD/new.sh"; manifest; echo X >> "$RD/app.apk"
req recovery
check "damaged file on the stick: nothing replaced" 'grep -qx "echo old" "$T/fake/bin/x.sh" && grep -q "damaged" "$LOG"'

# shut down + stay in golden mode: boot_retry=10 set, then the power off request
req "shutdown stay"
check "boot_retry=10 for the next boot" 'grep -qx "boot_retry=10" "$T/env"'
check "asked init to shut down" 'grep -qx "sys.powerctl shutdown" "$T/setprop.log"'

# shut down without stay must not touch boot_retry again
rm -f "$T/env" "$T/setprop.log"
req shutdown
check "plain shut down leaves boot_retry alone" '[ ! -e "$T/env" ] && grep -qx "sys.powerctl shutdown" "$T/setprop.log"'
req reboot
check "reboot asks init to reboot" 'grep -qx "sys.powerctl reboot" "$T/setprop.log"'
rm -f "$T/env"
req "reboot stay"; sleep 3
check "reboot stay: boot_retry=10 and reboot" 'grep -qx "boot_retry=10" "$T/env" && [ "$(grep -c "sys.powerctl reboot" "$T/setprop.log")" = 2 ]'

kill -0 $pid 2>/dev/null || { echo "   FAIL: script died - stderr: $(tail -2 "$T/stderr.txt")"; fail=1; }
grep -E 'ERROR' "$LOG" | sed 's/^/   log: /'
exit $fail
