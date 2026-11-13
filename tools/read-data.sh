#!/usr/bin/env bash
# OPTIONAL: yoinks /data (p6) and the u-boot env (p3) off a card you already used in the panel, so the next build keeps that state (installed apps, Wi-Fi, settings...) instead of starting from the extracted dump.
# only reads from the card, never writes to it.
#
#   tools/read-data.sh /dev/sdX [work/]
#
# without this tools/mod-data.py works on work/raw/p6.img as tools/extract.sh made it from your own dump, both ways are fine.
# re-run tools/extract.sh to go back.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

DEV=${1:?usage: read-data.sh </dev/sdX> [work/]}
WORK=${2:-work}
case "$DEV" in *[0-9]) P="${DEV}p6" ;; *) P="${DEV}6" ;; esac
[ -b "$P" ] || { echo "$P not found (give me the whole card, e.g. /dev/sdb or /dev/mmcblk0)" >&2; exit 1; }
if lsblk -no MOUNTPOINT "$P" | grep -q .; then echo "$P is mounted, unmount it first" >&2; exit 1; fi

SUDO=; [ -r "$P" ] || SUDO=sudo
want=$(stat -c %s "$WORK/raw/p6.img" 2>/dev/null || echo 0)
have=$($SUDO blockdev --getsize64 "$P")
[ "$want" = 0 ] || [ "$want" = "$have" ] || { echo "$P is $have bytes, expected $want (not a TSW card?)" >&2; exit 1; }

tmp="$WORK/raw/p6.img.new"
$SUDO dd if="$P" of="$tmp" bs=4M iflag=direct status=progress
[ -n "$SUDO" ] && sudo chown "$(id -u):$(id -g)" "$tmp"
debugfs -R "stat /system/packages.xml" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; echo "$P doesnt look like the panels /data" >&2; exit 1; }
mv "$tmp" "$WORK/raw/p6.img"
# u-boots environment too (p3), crestrons scripts change it and an old copy would undo that
case "$DEV" in *[0-9]) P3="${DEV}p3" ;; *) P3="${DEV}3" ;; esac
SUDO3=; [ -r "$P3" ] || SUDO3=sudo
$SUDO3 dd if="$P3" of="$WORK/raw/p3.img.new" bs=64k status=none
[ -n "$SUDO3" ] && sudo chown "$(id -u):$(id -g)" "$WORK/raw/p3.img.new"
python3 "$(dirname "$0")/ubootenv.py" --img "$WORK/raw/p3.img.new" print boot_retry >/dev/null \
    && mv "$WORK/raw/p3.img.new" "$WORK/raw/p3.img" || { rm -f "$WORK/raw/p3.img.new"; echo "p3: no valid u-boot env, kept the old copy" >&2; }
echo "work/raw/p6.img + p3.img now hold the cards /data and u-boot env, next up is tools/mod-data.py + tools/pack.sh"
