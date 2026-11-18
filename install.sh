#!/usr/bin/env bash
# puts crusty on the NEXT TSW-760, after ./setup.sh did the first one. no full card dump, no rebuild of apps / eMMC images, those get reused.
#   ./install.sh              interactive, plug in the stock microSD card of the next panel and follow it
#   ./install.sh --dry-run    analyse + build the cards parts, but write nothing to the card or stick
#   ./install.sh --full-backup  also dump the whole stock card to img/<MAC>-sdcard.img first (slow, normally not needed)
#
# what is per panel and what is shared (checked on two stock cards, see docs/ANALYSIS.md, "More panels"):
#   shared, same bytes on every panel with this firmware: p1 (boot.img), the files in p2 (golden /system), the built apps, the eMMC update/restore images, the USB stick
#   per panel: p3 (u-boot env: MAC, serial, hostname), p6 (/data, it has the hostname + MAC + tsid in there too), p5 (Crestron registry/config, project) and p8 (logs)
# so only p2, p3 and p6 of the card are touched, each one patched from the cards OWN content (never copied from the first panel), p1/p5/p7/p8 stay as they are.
# no, we dont yeet the first panels clean /data onto the new one, it would clone the hostname and MAC of panel 1 (no bueno), so p6 stays the cards own and tools/clean-data.py empties the apps data + crash logs.
# the Sonos app some panels come with just gets disabled (config/disable-packages.txt).
# the stock p3 + p6 of the panel are kept in work/panels/<MAC>/stock/, together with img/sdcard.img (p2 is the same on every panel) that is everything needed to put the card back to stock.
# what cant be seen from the card: the internal eMMC. golden mode checks it before writing (install only touches an eMMC it knows) and can back it up first.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:/usr/sbin:/sbin"

STATE=work/.setup-step
SETUP_STEPS=10      # steps in setup.sh, the state file says 10 once s_done ran
TITLE="crusty install"
DRY=0; FULL=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --full-backup) FULL=1 ;;
        -h|--help) sed -n 2,6p "$0"; exit 0 ;;
        *) echo "unknown option $a" >&2; exit 1 ;;
    esac
done
source tools/lib.sh

dcat() { debugfs -R "cat $2" "$1" 2>/dev/null; }                  # <ext4 image> <path>
md5of() { md5sum | cut -d' ' -f1; }
envv() { python3 tools/ubootenv.py --img "$1" print "$2" 2>/dev/null | head -1 | cut -d= -f2-; }
refenv() { grep -m1 "^$1=" work/raw/env.txt | cut -d= -f2-; }       # env of the first panel, stock
slices() { sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2/p' | sort -n; }

# ------------------------------------------------------------------ did setup.sh finish?
preflight() {
    local cur=0 missing=() f
    [ -f "$STATE" ] && cur=$(cat "$STATE")
    [ "$cur" -ge "$SETUP_STEPS" ] 2>/dev/null \
        || die "setup.sh hasnt finished yet (it is at step $cur of $SETUP_STEPS).\n\nrun ./setup.sh to the end on the first panel, this script reuses what it built."
    for f in work/apps/dev.crusty.companion.apk work/raw/p2.img work/raw/env.txt work/raw/partitions.sfdisk work/fat/boot.img \
             work/system/build.prop out/crusty-emmc-update/MANIFEST out/crusty-emmc-restore/MANIFEST; do
        [ -f "$f" ] || missing+=("$f")
    done
    [ ${#missing[@]} = 0 ] || die "setup.sh says it is done but this is missing: ${missing[*]}\n\nrun ./setup.sh update to build it again."
    [ "$(dcat work/raw/p2.img /bin/crestInit.sh | grep -c crusty)" -gt 0 ] \
        || die "work/raw/p2.img has no crusty golden mode in it, run ./setup.sh update first."
    check_tools
}

# ------------------------------------------------------------------ the card
read_part() {   # <partition number> <out file>
    local p; p=$(part "$SD" "$1")
    $SUDO dd if="$p" of="$2" bs=4M status=none || die "couldnt read $p"
    [ -n "$SUDO" ] && sudo chown "$(id -u):$(id -g)" "$2"
    return 0
}

analyse() {   # sets TSID PD CRUSTY_ALREADY
    step "reading the card (read only)"
    SUDO=; [ -r "$SD" ] || SUDO=sudo
    unmount_all "$SD"

    # same layout? everything below writes at the offsets of the first panels table
    local mine ref
    mine=$($SUDO sfdisk -d "$SD" | slices); ref=$(slices < work/raw/partitions.sfdisk)
    [ "$mine" = "$ref" ] || die "the partition layout of $SD is not the one of the first panel,\nthis is not the same card layout (other model or firmware?).\n\nthat needs its own ./setup.sh run."

    mkdir -p work/panels/.tmp
    local tmp=work/panels/.tmp
    read_part 3 "$tmp/p3.img"
    TSID=$(envv "$tmp/p3.img" tsid)
    MAC=$(envv "$tmp/p3.img" ethaddr | tr -d ':' | tr 'a-f' 'A-F')
    [ -n "$TSID" ] && [ -n "$MAC" ] || die "no u-boot environment with a tsid and ethaddr on that card's p3, is it a TSW card?"
    # panels are named after their ethernet MAC, the one printed on the device (folders used to be named after the tsid)
    PD=work/panels/$MAC
    [ -d "work/panels/$TSID" ] && [ ! -d "$PD" ] && mv "work/panels/$TSID" "$PD"
    mkdir -p "$PD/stock" "$PD/raw"
    local model ref_model
    model=$(envv "$tmp/p3.img" product_name); ref_model=$(refenv product_name)
    [ "${model%%,_#*}" = "${ref_model%%,_#*}" ] \
        || die "this panel is a different model / firmware:\n  this:  $model\n  first: $ref_model\n\nthe build is made for the first one, run ./setup.sh for this panel instead."
    for k in aml_dt lcdsize; do
        [ "$(envv "$tmp/p3.img" $k)" = "$(refenv $k)" ] || die "$k differs from the first panel ($(envv "$tmp/p3.img" $k) / $(refenv $k)), needs its own ./setup.sh run."
    done

    echo ">> p1: boot.img"
    read_part 1 "$tmp/p1.img"
    [ "$(7z e -so "$tmp/p1.img" boot.img 2>/dev/null | md5of)" = "$(md5of < work/fat/boot.img)" ] \
        || die "boot.img on that card is not the one of the first panel (other firmware), needs its own ./setup.sh run."

    echo ">> p2: golden /system"
    read_part 2 "$PD/raw/p2.img"
    CRUSTY_ALREADY=0
    [ -n "$(dcat "$PD/raw/p2.img" /bin/crestInit.sh.crestron | head -c 1)" ] && CRUSTY_ALREADY=1
    local stock_init="/bin/crestInit.sh"; [ $CRUSTY_ALREADY = 1 ] && stock_init="/bin/crestInit.sh.crestron"
    local ref_init="/bin/crestInit.sh.crestron"
    [ "$(dcat "$PD/raw/p2.img" $stock_init | md5of)" = "$(dcat work/raw/p2.img $ref_init | md5of)" ] \
        || die "crestInit.sh on that card differs from the first panel's (other firmware)."
    [ "$(dcat "$PD/raw/p2.img" /build.prop | md5of)" = "$(md5of < work/system/build.prop)" ] \
        || die "build.prop on that card differs from the first panel's (other firmware)."

    echo ">> p6: /data"
    read_part 6 "$PD/raw/p6.img"
    debugfs -R "stat /system/packages.xml" "$PD/raw/p6.img" >/dev/null 2>&1 || die "p6 doesnt look like the panels /data."

    # stock backups of what is unique to this panel, never overwritten (a card that already has crusty on it would replace them with modded data lol)
    if [ ! -f "$PD/stock/p3.img" ]; then
        if [ $CRUSTY_ALREADY = 1 ]; then
            msg "this card already has crusty on it and there is no stock backup of this panel in $PD/stock/.\n\nnot a problem for the install, but the original p3/p6 of this panel are gone (the eMMC backup from golden mode still has the eMMC)."
        else
            cp "$tmp/p3.img" "$PD/stock/p3.img"; cp "$PD/raw/p6.img" "$PD/stock/p6.img"
            envv_all="$PD/stock/env.txt"; python3 tools/ubootenv.py --img "$PD/stock/p3.img" print > "$envv_all"
        fi
    fi
    cp "$tmp/p3.img" "$PD/raw/p3.img"
    rm -rf "$tmp"
}

full_backup() {
    local out=img/$MAC-sdcard.img
    step "full backup of the stock card -> $out"
    [ -f "$out" ] && { echo "$out exists, keeping it"; return 0; }
    run $SUDO dd if="$SD" of="$out.part" bs=4M iflag=direct status=progress
    [ -n "$SUDO" ] && sudo chown "$(id -u):$(id -g)" "$out.part"
    mv "$out.part" "$out"
}

summary() {
    local host mac pn
    host=$(envv "$PD/raw/p3.img" lan_hostname); mac=$(envv "$PD/raw/p3.img" ethaddr); pn=$(envv "$PD/raw/p3.img" product_name)
    {
        echo "mac      $mac"; echo "tsid     $TSID"; echo "hostname $host"; echo "product  $pn"
        echo "date     $(date '+%F %T')"; echo "card     $SD"
    } > "$PD/info.txt"
    msg "this is a TSW-760 with the same firmware as the first panel:\n\n\
  $pn\n  hostname $host   mac $mac\n\n\
what gets written to the card (only what differs, each part patched from THIS cards own content):\n\
  p2  golden mode  (crusty recovery + tools)\n\
  p3  u-boot env   (panels MAC / serial / hostname, boot_retry=10)\n\
  p6  /data        (panels own /data, aka. its hostname / serial / MAC\n\
                    crusty app, settings, disabled apps + ssh keys)\n\
NOT touched: p1, p5 (crestron reg, config, project), p7, p8 (logs).\n\n\
stock p3 + p6 of this panel: $PD/stock/  (folders are named after the MAC)\n\
$([ $CRUSTY_ALREADY = 1 ] && echo 'note: the card already had crusty on it, only updating it!')"
}

build() {
    step "building this panels parts"
    run python3 tools/mod-golden.py --system "$PD/raw/p2.img"
    run python3 tools/clean-data.py --data "$PD/raw/p6.img"
    run python3 tools/mod-data.py --data "$PD/raw/p6.img"
    run python3 tools/ubootenv.py --img "$PD/raw/p3.img" golden
    run python3 tools/build-recovery.py
    # pack.sh wants a base image: an empty one with the first panels partition table, only p2 p3 p6 get laid over it and written
    rm -f "$PD/base.img"
    truncate -s "$(lsblk -bdno SIZE "$SD")" "$PD/base.img"
    sfdisk -q "$PD/base.img" < work/raw/partitions.sfdisk || die "couldnt make the base image"
    run tools/pack.sh "$PD/base.img" "$PD" "$PD/sdcard-mod.img"
}

prepare_stick() {
    ask "prepare the USB stick now?\n\nit needs crusty-emmc-update/, crusty-emmc-restore/ and crusty-recovery-update/, the same stick works for every panel,\nonly changed parts get written (a stick that is already up to date takes seconds)." || return 0
    mount_stick || return 1
    run python3 tools/sync-stick.py "$STICK_MNT" out/crusty-emmc-update out/crusty-emmc-restore out/crusty-recovery-update
    eject_stick
}

# ------------------------------------------------------------------ main
preflight
msg "this puts crusty on the next panel, reusing what ./setup.sh built:\n\n\
 1. plug in the STOCK microSD card of that panel (card reader)\n\
 2. it gets read (nothing is written), checked against the first panel\n\
 3. only the parts that are unique to this panel get patched: p2, p3, p6\n\
 4. only the changed chunks are written to the card\n\
 5. USB stick, then panel: golden mode -> update eMMC\n\n\
no full dump, no rebuild of apps or eMMC images.$([ $DRY = 1 ] && echo '\n\n(dry run: nothing gets written)')"
pick_sd || exit 1
analyse
[ $FULL = 1 ] && full_backup
summary
build
if [ $DRY = 1 ]; then
    echo; echo "dry run done, the card image for this panel is $PD/sdcard-mod.img (p2 p3 p6 on an empty base), nothing was written."
    exit 0
fi
ask "write it to $SD now?" || { echo "stopped, run ./install.sh again."; exit 1; }
unmount_all "$SD"
run tools/flash.sh --incremental --only p2,p3,p6 "$PD/sdcard-mod.img" "$SD"
prepare_stick
msg "card done. now on the panel:\n\n\
1. open the panel, put the microSD card back in, plug in the USB stick\n\
2. power on, it starts in crustys golden mode (recovery)\n\
3. recommended once per panel: \"Back up eMMC to USB stick\" (own backup of this panel, ~10 min)\n\
4. \"Update eMMC from USB stick\", wait for \"install DONE + verified\"\n\
   (it only writes an eMMC it knows, a panel with a different eMMC content gets refused and nothing is changed)\n\
5. \"Reboot to the normal system\"\n\n\
this panel: MAC $MAC (tsid $TSID), files in $PD/"
