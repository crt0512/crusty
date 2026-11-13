#!/bin/bash
# PC side test of the golden scripts install / restore actions (app/golden/crestInit.sh) with fake partitions (files) and a fake USB stick (dir) holding crusty-emmc-update/ + crusty-emmc-restore/.
#   tests/golden/install.sh [script]
# everything happens in a temp dir that gets removed again, run it as often as ya want.
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../app/golden/crestInit.sh}
SH=$(command -v mksh || echo "busybox sh")
T=$(mktemp -d "${TMPDIR:-/tmp}/crusty-install-test.XXXX")
trap 'case "$T" in "${TMPDIR:-/tmp}"/crusty-*) rm -r "$T" ;; esac' EXIT
mkdir -p "$T/data" "$T/dev" "$T/usb/crusty-emmc-update" "$T/usb/crusty-emmc-restore"
: > "$T/dev/sda1"
echo "/dev/block/vold/8:1 $T/usb vfat rw 0 0" > "$T/mounts"
printf "major minor  #blocks  name\n\n 179 16 3072 mmcblk1\n" > "$T/partitions"
md5() { md5sum "$1" | cut -d' ' -f1; }
head -c 1048576 /dev/urandom > "$T/orig-system"; head -c 65536 /dev/urandom > "$T/orig-logo"
head -c 1048576 /dev/urandom > "$T/usb/crusty-emmc-update/system.img"; head -c 65536 /dev/urandom > "$T/usb/crusty-emmc-update/logo.img"
cp "$T/orig-system" "$T/usb/crusty-emmc-restore/system.img"; cp "$T/orig-logo" "$T/usb/crusty-emmc-restore/logo.img"
U=$T/usb/crusty-emmc-update; R=$T/usb/crusty-emmc-restore
printf "system system.img 1024 %s %s\nlogo logo.img 64 %s %s\n" "$(md5 $U/system.img)" "$(md5 $T/orig-system)" \
    "$(md5 $U/logo.img)" "$(md5 $T/orig-logo)" > "$U/MANIFEST"
printf "system system.img 1024 %s *\nlogo logo.img 64 %s *\n" "$(md5 $R/system.img)" "$(md5 $R/logo.img)" > "$R/MANIFEST"
cp "$T/orig-system" "$T/dev/system"; cp "$T/orig-logo" "$T/dev/logo"
chunks() {  # chunk list like tools/build-emmc.py, 64 KiB chunks
    { echo "# chunk_kib 64"; n=$(( $(stat -c %s "$1") / 65536 )); i=0
      while [ $i -lt $n ]; do dd if="$1" bs=65536 skip=$i count=1 status=none | md5sum | cut -d' ' -f1; i=$((i+1)); done; } > "$1.chunks"
}
for f in "$U"/*.img "$R"/*.img; do chunks "$f"; done

sed -e "s|^BB=/system/bin/busybox|BB=$HERE/bb|" -e "s|^DIR=/data/crusty|DIR=$T/data/crusty|" -e "s|^USB=/mnt/crusty_usb|USB=$T/usb|" \
    -e "s|/proc/mounts|$T/mounts|g" -e "s|/proc/partitions|$T/partitions|g" -e "s|/dev/crusty_|$T/crusty_|g" \
    -e "s|/proc/sys/vm/drop_caches|/dev/null|g" -e "s|/dev/block/|$T/dev/|g" -e "s|/system/bin/fw_printenv|true|; s|/system/bin/fw_setenv|true|g" \
    -e "s|/system/bin/dd|$HERE/dd|g" -e "s|\[ -b |[ -e |g" -e "s|\[ ! -b |[ ! -e |g" -e "s|^start watchdog|: start watchdog|" -e "s|dmesg |true |" "$SRC" > "$T/golden-test.sh"
$SH "$T/golden-test.sh" 2>"$T/stderr.txt" & pid=$!
sleep 2
req() {  # $1 request, $2 label
    echo "$1" > "$T/data/crusty/golden-request"; sleep 3
    echo "== $2: $(cat "$T/data/crusty/golden-status")"
}
state() {
    s=$(md5 "$T/dev/system"); l=$(md5 "$T/dev/logo")
    [ "$s" = "$(md5 $U/system.img)" ] && s=CRUSTY || { [ "$s" = "$(md5 $T/orig-system)" ] && s=ORIGINAL || s=OTHER; }
    [ "$l" = "$(md5 $U/logo.img)" ] && l=CRUSTY || { [ "$l" = "$(md5 $T/orig-logo)" ] && l=ORIGINAL || l=OTHER; }
    echo "   partitions: system=$s logo=$l"
}
state
req install "install";            state
req install "install again";      state
req restore "restore";            state
printf 'X' | dd of="$T/dev/system" bs=1 seek=10 conv=notrunc status=none   # someone changed it
req install "install over unknown content"; state
req restore "restore from unknown content"; state
printf 'X' | dd of="$U/system.img" bs=1 seek=10 conv=notrunc status=none   # damaged image on the stick
req install "install with a damaged image"; state
# incremental: a new crusty build that differs from the installed one in only 2 chunks
req restore "restore (reset)"; state
cp "$U/system.img" "$T/prev-crusty"; chunks "$U/system.img"
printf "system system.img 1024 %s %s\nlogo logo.img 64 %s %s\n" "$(md5 $U/system.img)" "$(md5 $T/orig-system)" \
    "$(md5 $U/logo.img)" "$(md5 $T/orig-logo)" > "$U/MANIFEST"
req install "install (fresh)"; state
printf 'AB' | dd of="$U/system.img" bs=1 seek=$((3 * 65536 + 5)) conv=notrunc status=none
printf 'CD' | dd of="$U/system.img" bs=1 seek=$((9 * 65536 + 7)) conv=notrunc status=none
chunks "$U/system.img"
printf "system system.img 1024 %s %s,%s\nlogo logo.img 64 %s %s\n" "$(md5 $U/system.img)" "$(md5 $T/orig-system)" \
    "$(md5 $T/prev-crusty)" "$(md5 $U/logo.img)" "$(md5 $T/orig-logo)" > "$U/MANIFEST"
req install "install new build (2 chunks differ)"; state
grep -E 'need writing|changed chunks' "$T/data/crusty/golden.log" | tail -2 | sed 's/^/   log: /'
# a damaged chunk on the stick has to be refused BEFORE anything gets written
printf 'X' | dd of="$U/system.img" bs=1 seek=$((5 * 65536)) conv=notrunc status=none
req restore "restore (reset)"; req install "install with a damaged chunk on the stick"; state
kill -0 $pid 2>/dev/null && echo "   script still alive: yes" || echo "   script DIED: $(tail -2 "$T/stderr.txt")"
kill $pid 2>/dev/null; wait $pid 2>/dev/null

exit 0
