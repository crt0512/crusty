#!/usr/bin/env bash
# rebuilds a full SD card image from the original dump + the (modified) partition images, no root needed, rerun whenever.
#
#   tools/pack.sh [img/sdcard.img] [work/] [out/sdcard-mod.img]
#
# starts from a copy of the original dump so bootloader, env, MBR and any unpartitioned data stay byte-identical, then writes every work/raw/pN.img back to its partition offset.
# images that didnt change are skipped, images bigger than their partition get refused.
#
# the usual edit loop:
#   tools/extract.sh
#   # system (ext4):  debugfs -w -R "write local.file /path/in/fs" work/raw/p2.img
#   # boot.img:       tools/bootimg.py repack work/boot work/boot-new.img
#   #                 then put it into p1 (FAT): mcopy -o -i work/raw/p1.img work/boot-new.img ::boot.img
#   tools/pack.sh
#   tools/flash.sh out/sdcard-mod.img /dev/sdX
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

IMG=${1:-img/sdcard.img}
WORK=${2:-work}
OUT=${3:-out/sdcard-mod.img}

mkdir -p "$(dirname "$OUT")"
echo ">> copying base image -> $OUT"
cp --reflink=auto "$IMG" "$OUT"

sfdisk -J "$IMG" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p["type"] != "5":
        print(p["node"].rsplit("img",1)[1], p["start"], p["size"])
' | while read -r n start size; do
    part="$WORK/raw/p$n.img"
    [ -f "$part" ] || continue
    psize=$(stat -c %s "$part")
    if [ "$psize" -gt $((size * 512)) ]; then
        echo "!! p$n.img is $psize bytes, the partition only has $((size * 512))" >&2; exit 1
    fi
    if cmp -s "$part" <(dd if="$IMG" bs=512 skip="$start" count="$size" status=none); then
        echo "   p$n unchanged"
        continue
    fi
    echo "   p$n changed -> writing at sector $start"
    dd if="$part" of="$OUT" bs=512 seek="$start" conv=notrunc status=none
done
sha256sum "$OUT"
