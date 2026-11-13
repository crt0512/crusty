#!/bin/bash
# PC side test of the golden mode script (app/golden/crestInit.sh), backup action, in a fake environment: a 3 MiB "eMMC", a directory as "USB stick" and a mock busybox (tests/golden/bb).
# androids shell is mksh with 32-bit arithmetic, install mksh (apt install mksh) to test exactly that, otherwise busybox sh gets used and its 64-bit arithmetic wont catch overflows.
#   tests/golden/run.sh [script]
#   BROKEN_STATF=1 tests/golden/run.sh   (busybox without stat -f)
# the parts are shrunk to 1 MiB (split -b) so the 3 MiB eMMC gives 3 of them.
# everything happens in a temp dir that gets removed again, run it as often as ya want.
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../app/golden/crestInit.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/crusty-golden-test.XXXX")
trap 'case "$T" in "${TMPDIR:-/tmp}"/crusty-*) rm -r "$T" ;; esac' EXIT
mkdir -p "$T/data" "$T/dev" "$T/usb"
head -c 3145728 /dev/urandom > "$T/dev/mmcblk1"; head -c 65536 /dev/urandom > "$T/dev/mmcblk1boot0"
cp "$T/dev/mmcblk1boot0" "$T/dev/mmcblk1boot1"; : > "$T/dev/sda1"
echo "/dev/block/vold/8:1 $T/usb vfat rw 0 0" > "$T/mounts"
printf "major minor  #blocks  name\n\n 179       16 %10s mmcblk1\n" "${FAKE_KIB:-3072}" > "$T/partitions"
SH=$(command -v mksh || echo "busybox sh")
echo "   shell: $SH"
sed -e "s|^BB=/system/bin/busybox|BB=$HERE/bb|" -e "s|^DIR=/data/crusty|DIR=$T/data/crusty|" -e "s|^USB=/mnt/crusty_usb|USB=$T/usb|" \
    -e "s|/proc/mounts|$T/mounts|g" -e "s|/proc/partitions|$T/partitions|g" -e "s|/dev/crusty_|$T/crusty_|g" -e "s|/proc/sys/vm/drop_caches|/dev/null|g" -e "s|/dev/block/|$T/dev/|g" -e "s|/system/bin/fw_printenv|true|; s|/system/bin/fw_setenv|true|g" \
    -e "s|/system/bin/dd|dd|g" -e "s|\[ -b |[ -e |g" -e "s|\[ ! -b |[ ! -e |g" -e "s|count=1024 skip=\$((n \* 1024))|count=1 skip=\$n|" \
    -e "s|split -b 1073741824|split -b 1048576|" -e "s|^start watchdog|: start watchdog|" -e "s|dmesg |true |" "$SRC" > "$T/golden-test.sh"
$SH "$T/golden-test.sh" 2>"$T/stderr.txt" & pid=$!
sleep 3; echo "   idle status: $(cat "$T/data/crusty/golden-status")"
echo backup > "$T/data/crusty/golden-request"
sleep 6
echo "   status after request: $(cat "$T/data/crusty/golden-status")"
kill -0 $pid 2>/dev/null && echo "   script still alive: yes" || echo "   script still alive: NO (died) - stderr: $(tail -1 "$T/stderr.txt")"
kill $pid 2>/dev/null; wait $pid 2>/dev/null
for d in "$T"/usb/crusty-emmc-*; do
    [ -d "$d" ] || continue
    echo "   backup files: $(ls "$d" | tr '\n' ' ')"
    want=$(md5sum < "$T/dev/mmcblk1" | cut -d' ' -f1)
    got=$(cat "$d"/mmcblk1.part* | md5sum | cut -d' ' -f1)
    rec=$(head -1 "$d/MD5SUMS" | cut -d' ' -f1)
    [ "$want" = "$got" ] && [ "$want" = "$rec" ] && echo "   PC check: parts == fake eMMC == MD5SUMS ($want)" \
        || echo "   PC check: MISMATCH eMMC=$want parts=$got MD5SUMS=$rec"
done
grep -E 'ERROR|DONE|verifying|unknown|trying anyway' "$T/data/crusty/golden.log" | sed 's/^/   log: /'

exit 0
