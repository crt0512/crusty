#!/usr/bin/env bash
# helpers shared by setup.sh and install.sh (dialogs, picking the SD card / USB stick, tool check), sourced, not run.
# the caller sets TITLE and does set -uo pipefail itself.
# ------------------------------------------------------------------ ui
if [ -n "${CRUSTY_UI:-}" ]; then UI=$CRUSTY_UI        # CRUSTY_UI=plain forces the plain prompts (tests, no terminal)
elif command -v whiptail >/dev/null; then UI=whiptail
elif command -v dialog >/dev/null; then UI=dialog
else UI=plain; fi

msg() {   # $1 text
    if [ $UI = plain ]; then printf '\n%b\n\n' "$1"; read -rp "[enter] " _
    else $UI --title "$TITLE" --msgbox "$1" 22 76; fi
}
ask() {   # $1 text -> 0 = yes
    if [ $UI = plain ]; then printf '\n%b\n' "$1"; read -rp "[y/N] " a; [[ $a == [yY]* ]]
    else $UI --title "$TITLE" --yesno "$1" 22 76; fi
}
menu() {  # $1 text, then tag/label pairs -> chosen tag on stdout
    local text=$1; shift
    if [ $UI = plain ]; then
        printf '\n%b\n' "$text" >&2
        local tags=() i=1
        while [ $# -gt 0 ]; do printf '  %d) %s\n' $i "$2" >&2; tags+=("$1"); shift 2; i=$((i + 1)); done
        read -rp "> " n
        [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#tags[@]} ] && echo "${tags[$((n - 1))]}"
    else
        $UI --title "$TITLE" --menu "$text" 22 76 10 "$@" 3>&1 1>&2 2>&3
    fi
}
step() { clear 2>/dev/null; printf '\n\033[1m== %s\033[0m\n\n' "$1"; }
die() { printf '\n\033[31m%s\033[0m\n' "$1" >&2; read -rp "[enter] " _; exit 1; }
run() { echo "\$ $*"; "$@" || die "failed: $*"; }
done_step() { mkdir -p work; echo "$1" > "$STATE"; }

# ------------------------------------------------------------------ devices
# removable disks (SD readers, USB sticks), "dev|size|model" per line
removable_disks() {
    lsblk -dpnbo NAME,SIZE,RM,TRAN,MODEL | while read -r name size rm tran model; do
        case "$name" in /dev/loop*|/dev/zram*|/dev/sr*) continue ;; esac
        [ "$rm" = 1 ] || [ "$tran" = usb ] || [[ $name == /dev/mmcblk* ]] || continue
        [ "$size" -gt 0 ] || continue
        echo "$name|$((size / 1000000)) MB|${model:-$tran}"
    done
}

pick_disk() {   # $1 what -> device on stdout, the list can be refreshed after plugging something in
    local items d s m text choice
    while true; do
        items=()
        while IFS='|' read -r d s m; do items+=("$d" "$s  $m"); done < <(removable_disks)
        if [ ${#items[@]} -gt 0 ]; then
            text="which one is the $1?\n\nlook at the size TWICE, whatever you pick here gets read or written.\n\nnot in the list? plug it in and pick refresh."
        else
            text="no removable disk found.\n\nplug in the $1, give it a second, then pick refresh."
        fi
        choice=$(menu "$text" "${items[@]}" refresh "refresh the list") || return 1
        [ -n "$choice" ] || return 1
        [ "$choice" = refresh ] || { echo "$choice"; return 0; }
    done
}

part() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "$1$2" ;; esac; }

pick_sd() {   # -> $SD, checked to look like a TSW-760 card
    while true; do
        SD=$(pick_disk "panel's microSD card") || return 1
        [ -n "$SD" ] || return 1
        local n; n=$(lsblk -lnpo NAME "$SD" | grep -c "^$SD.\+")
        if [ "$n" -ge 8 ] && lsblk -no LABEL "$(part "$SD" 5)" 2>/dev/null | grep -q sdcard; then return 0; fi
        ask "$SD doesnt look like a TSW-760 card (expected 8 partitions, p5 labelled \"sdcard\").\n\nuse it anyway?" && return 0
    done
}

unmount_all() {   # $1 disk
    local p
    for p in $(lsblk -lnpo NAME "$1" | tail -n +2); do
        lsblk -no MOUNTPOINT "$p" | grep -q . || continue
        udisksctl unmount -b "$p" >/dev/null 2>&1 || sudo umount "$p"
    done
}

STICK_MNT=
mount_stick() {   # -> $STICK_MNT (first partition of a FAT32 stick)
    local dev p fs
    dev=$(pick_disk "USB stick") || return 1
    [ -n "$dev" ] || return 1
    p=$(part "$dev" 1); [ -b "$p" ] || p=$dev
    fs=$(lsblk -no FSTYPE "$p")
    [ "$fs" = vfat ] || { msg "$p is \"$fs\", not FAT32. format the stick as FAT32 (one partition) first."; return 1; }
    STICK_MNT=$(lsblk -no MOUNTPOINT "$p" | head -1)
    if [ -z "$STICK_MNT" ]; then
        udisksctl mount -b "$p" >/dev/null || return 1
        STICK_MNT=$(lsblk -no MOUNTPOINT "$p" | head -1)
    fi
    STICK_DEV=$dev
    [ -n "$STICK_MNT" ]
}

eject_stick() { sync; unmount_all "$STICK_DEV"; udisksctl power-off -b "$STICK_DEV" >/dev/null 2>&1 || true; }

# ------------------------------------------------------------------ checks
check_tools() {
    local miss=() c
    for c in python3 java curl unzip 7z openssl keytool sfdisk debugfs e2fsck resize2fs dumpe2fs \
             cpio gzip lz4 md5sum sha256sum lsblk udisksctl; do
        command -v "$c" >/dev/null || miss+=("$c")
    done
    [ ${#miss[@]} = 0 ] && return 0
    msg "missing programs: ${miss[*]}\n\non Debian/Ubuntu:\n  sudo apt install python3 default-jdk curl unzip p7zip-full openssl \\\\\n    e2fsprogs fdisk cpio gzip lz4 udisks2 whiptail\n\nthen run ./$(basename "$0") again."
    exit 1
}
