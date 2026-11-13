#!/usr/bin/env bash
# splits the TSW-760 SD card dump into its pieces, no root needed.
#
#   tools/extract.sh [img/sdcard.img] [work/]
#
# what falls out:
#   work/raw/bootloader.bin   first 1 MiB (Amlogic BL1/SPL + u-boot, raw, before p3)
#   work/raw/env.txt          u-boot environment (p3, 1 MiB @ 1 MiB) as text
#   work/raw/pN.img           every MBR partition as a separate image
#   work/fat/                 contents of p1 (FAT16, holds boot.img)
#   work/boot/                unpacked boot.img (kernel uImage, ramdisk, dtb)
#   work/boot/initramfs/      extracted ramdisk
#   work/boot/dtbs/           per-board device trees (from AML_ multi-dtb in "second")
#   work/system/              rdump of p2 (Android /system, ext4)
# rerun whenever, existing outputs just get overwritten.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

IMG=${1:-img/sdcard.img}
OUT=${2:-work}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT/raw"
echo ">> partition table"
sfdisk -d "$IMG" | tee "$OUT/raw/partitions.sfdisk"

echo ">> bootloader + env"
dd if="$IMG" of="$OUT/raw/bootloader.bin" bs=1M count=1 status=none
dd if="$IMG" bs=512 skip=2048 count=2048 status=none | tail -c +5 | tr '\0' '\n' \
    | sed '/^$/,$d' > "$OUT/raw/env.txt"

echo ">> partitions"
sfdisk -J "$IMG" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p["type"] != "5":
        print(p["node"].rsplit("img",1)[1], p["start"], p["size"])
' | while read -r n start size; do
    echo "   p$n  start=$start size=$size"
    dd if="$IMG" of="$OUT/raw/p$n.img" bs=512 skip="$start" count="$size" status=none
done

echo ">> p1 (FAT)"
rm -rf "$OUT/fat"; mkdir -p "$OUT/fat"
7z x -y -o"$OUT/fat" "$OUT/raw/p1.img" >/dev/null

echo ">> boot.img"
rm -rf "$OUT/boot"
python3 "$HERE/bootimg.py" unpack "$OUT/fat/boot.img" "$OUT/boot"
python3 "$HERE/uimage.py" "$OUT/boot/kernel" "$OUT/boot/zImage" || true
mkdir -p "$OUT/boot/initramfs"
( cd "$OUT/boot/initramfs" && { gzip -dc ../ramdisk 2>/dev/null || lz4 -dc ../ramdisk 2>/dev/null || cat ../ramdisk; } \
    | cpio -idm --quiet --no-absolute-filenames 2>/dev/null ) || echo "   (ramdisk: no idea what compression that is)"
for f in dtb second; do
    [ -f "$OUT/boot/$f" ] && python3 "$HERE/dtb.py" split "$OUT/boot/$f" "$OUT/boot/dtbs" && break
done

echo ">> p2 (system, ext4) via debugfs rdump"
rm -rf "$OUT/system"; mkdir -p "$OUT/system"
debugfs -R "rdump / $OUT/system" "$OUT/raw/p2.img" 2>/dev/null
echo "done -> $OUT"
