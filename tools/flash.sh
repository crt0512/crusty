#!/usr/bin/env bash
# writes a card image to an SD card, with sanity checks and progress that isnt lying to you.
#
#   tools/flash.sh [--incremental [--only p6[,p1...]]] out/sdcard-mod.img /dev/sdX
#
#   --incremental  compares card and image chunk by chunk (4 MiB), only writes the chunks that differ and then verifies those.
#                  reading costs no flash wear, so this is the card friendly way to re-flash a card that already has crusty on it.
#   --only p6      with --incremental: only compare/write these partitions (faster scan).
#
# unmounts the cards partitions if the desktop auto-mounted them (thanks desktop).
# refuses to write to non-removable disks or disks smaller than the image, and asks before it writes anything.
# writes and verifies with O_DIRECT, so the progress shown is what actually reaches the card (not the page cache) and the verify really reads the card back.
set -euo pipefail

USAGE="usage: flash.sh [--incremental [--only p6,...]] <image> </dev/sdX>"
INCR=0; ONLY=
while [ $# -gt 0 ]; do
    case "$1" in
        --incremental|-i) INCR=1; shift ;;
        --only) ONLY=${2:?$USAGE}; shift 2 ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        --*) echo "no idea what '$1' means" >&2; echo "$USAGE" >&2; exit 1 ;;
        *) break ;;
    esac
done
[ -z "$ONLY" ] || [ "$INCR" = 1 ] || { echo "--only needs --incremental" >&2; exit 1; }
IMG=${1:?$USAGE}
DEV=${2:?$USAGE}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }
name=$(basename "$DEV")
[ -e "/sys/block/$name" ] || { echo "give me the whole disk (e.g. /dev/sdb, /dev/mmcblk0), not a partition" >&2; exit 1; }

removable=$(cat "/sys/block/$name/removable")
tran=$(lsblk -dno TRAN "$DEV" || true)
if [ "$removable" != 1 ] && [ "$tran" != usb ] && [[ "$name" != mmcblk* ]]; then
    echo "$DEV is not removable/usb/mmc, not touching that" >&2; exit 1
fi

isize=$(stat -c %s "$IMG")
dsize=$(lsblk -bdno SIZE "$DEV")
if [ "$dsize" -lt "$isize" ]; then
    echo "card is $dsize bytes, image needs $isize, get a bigger card" >&2; exit 1
fi
if [ $((isize % 512)) -ne 0 ]; then
    echo "image size is not a multiple of 512 bytes" >&2; exit 1
fi

# no sudo needed if we can already write the device (e.g. you are in group "disk")
SUDO=; [ -w "$DEV" ] && [ -r "$DEV" ] || SUDO=sudo

# unmounts anything the desktop auto-mounted, udisks needs no sudo so that gets tried first, umount is the fallback.
# only gets called after the user said yes.
unmount_card() {
    lsblk -lnpo NAME,MOUNTPOINT "$DEV" | awk '$2' | while read -r part mnt; do
        echo ">> unmounting $part ($mnt)"
        udisksctl unmount -b "$part" >/dev/null 2>&1 || sudo umount "$part"
    done
    if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
        echo "$DEV still has mounted partitions, not touching that:" >&2
        lsblk -no NAME,MOUNTPOINT "$DEV" | awk '$2' >&2
        exit 1
    fi
}

# before /data (p6) gets overwritten we keep the cards current /data, otherwise whatever was set up or logged on the panel since the image was built goes bye bye.
# lands in work/backups/, the last 5 are kept.
# (running tools/read-data.sh before building is how you get it into the new image.)
backup_data() {
    case ",${ONLY:-p6}," in *,p6,*) ;; *) return 0 ;; esac
    local p6 out
    case "$DEV" in *[0-9]) p6="${DEV}p6" ;; *) p6="${DEV}6" ;; esac
    [ -b "$p6" ] || return 0
    mkdir -p "$HERE/../work/backups"
    out="$HERE/../work/backups/data-$(date +%Y%m%d-%H%M%S).img"
    echo ">> saving the card's current /data first -> work/backups/$(basename "$out")"
    $SUDO dd if="$p6" of="$out" bs=4M iflag=direct status=none
    [ -n "$SUDO" ] && sudo chown "$(id -u):$(id -g)" "$out"
    if ! PATH="$PATH:/usr/sbin:/sbin" debugfs -R "stat /system/packages.xml" "$out" >/dev/null 2>&1; then
        rm -f "$out"; echo "   (not a panel /data, nothing saved)"; return 0
    fi
    ls -1t "$HERE"/../work/backups/data-*.img | tail -n +6 | while read -r old; do rm -f "$old"; done
}

lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEV"
if [ "$INCR" = 1 ]; then
    read -r -p "update $DEV to match $IMG (${ONLY:-whole card}, only changed chunks)? type 'yes': " ok
    [ "$ok" = yes ] || exit 1
    unmount_card
    backup_data
    exec $SUDO python3 "$HERE/flash-diff.py" "$IMG" "$DEV" ${ONLY:+--only "$ONLY"}
fi
read -r -p "overwrite ALL data on $DEV with $IMG? type 'yes' if you mean it: " ok
[ "$ok" = yes ] || exit 1
unmount_card
backup_data

echo ">> writing $(numfmt --to=iec "$isize") to $DEV"
$SUDO dd if="$IMG" of="$DEV" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
sync

echo ">> verifying (reading the card back)"
if $SUDO dd if="$DEV" bs=4M iflag=direct,count_bytes count="$isize" status=progress | cmp -n "$isize" - "$IMG"; then
    echo "verify OK, card matches the image"
else
    echo "!! VERIFY FAILED, the card does not match the image (flash again, if it keeps failing the card is toast)" >&2
    exit 1
fi
