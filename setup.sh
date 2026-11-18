#!/usr/bin/env bash
# holds your hand through putting crusty on a TSW-760, from cracking the panel open to the first boot.
#   ./setup.sh            first install (it remembers the step you are at in work/.setup-step, just run it again to continue)
#   ./setup.sh update     rebuild after changing something and write only what changed
# uses whiptail (or dialog) if ya have one of them, plain prompts otherwise.
# the heavy lifting happens in the scripts in tools/, this thing only strings them together and checks stuff in between.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:/usr/sbin:/sbin"

STATE=work/.setup-step
IMG=img/sdcard.img
BACKUP=work/emmc-backup
TITLE="crusty setup"

# shared dialogs + device pickers
source tools/lib.sh

# ------------------------------------------------------------------ steps
s_intro() {
    msg "this puts crusty on a Crestron TSW-760, the plan:\n\n\
 1. open the panel, take out its microSD card\n\
 2. copy the card to this PC (that copy is your backup)\n\
 3. build a crusty card and put it back\n\
 4. the panel dumps its internal eMMC to a USB stick (second backup)\n\
 5. build the eMMC update from that dump\n\
 6. the panel installs it\n\n\
you need: a card reader, a FAT32 USB stick of 8 GB or more, a few GB free here\n\
and some patience for the first build (it downloads Android SDK images).\n\n\
nothing from the panel ends up in this repo, your dumps stay in img/ and work/.\n\
all of this is at your own risk, both backups get you back to stock though."
    check_tools
    done_step 1
}

s_open() {
    msg "Step 1: open the panel\n\n\
- unplug it (PoE / power) and take it off the wall or table mount.\n\
- open the back cover, the microSD card sits in a slot on the main board.\n\
- take a photo BEFORE you pull anything so you know how it goes back.\n\
- take the card out and put it in your card reader."
    done_step 2
}

s_dump_sd() {
    step "Step 2: copy the panels card"
    if [ -f "$IMG" ] && ! ask "$IMG already exists. copy the card again (overwrites it)?\n\nNo = keep the copy we have."; then
        :
    else
        pick_sd || return 1
        unmount_all "$SD"
        local SUDO=; [ -r "$SD" ] || SUDO=sudo
        mkdir -p img
        run $SUDO dd if="$SD" of="$IMG.part" bs=4M iflag=direct status=progress
        [ -n "$SUDO" ] && sudo chown "$(id -u):$(id -g)" "$IMG.part"
        echo ">> reading the card again to check the copy"
        local a b
        a=$($SUDO dd if="$SD" bs=4M iflag=direct status=progress | md5sum | cut -d' ' -f1)
        b=$(md5sum < "$IMG.part" | cut -d' ' -f1)
        [ "$a" = "$b" ] || die "the copy doesnt match the card ($a / $b) - bad reader or bad card?"
        mv "$IMG.part" "$IMG"
        echo "   copy OK ($a)"
    fi
    run tools/extract.sh "$IMG" work
    done_step 3
}

ssh_keys() {   # config/ssh/authorized_keys for the panel's ssh server (optional)
    local f=config/ssh/authorized_keys k
    [ -s $f ] && return 0
    for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        [ -f "$k" ] || continue
        if ask "remote shell: the panel can run an ssh server (key login only, as root).\n\nlet $k log in?"; then
            mkdir -p config/ssh && cat "$k" >> $f
            echo ">> $k added to $f"
        fi
        return 0
    done
}

build_card() {   # SD card image with crusty + golden (maintenance) mode armed
    ssh_keys
    run tools/build-apps.sh
    run python3 tools/mod-data.py
    run python3 tools/mod-golden.py
    run python3 tools/ubootenv.py golden
    run tools/pack.sh
}

write_card() {
    pick_sd || return 1
    unmount_all "$SD"
    run tools/flash.sh --incremental out/sdcard-mod.img "$SD"
}

s_build_sd() {
    step "Step 3: build the crusty card"
    build_card
    msg "now the card gets written. only the parts that differ from whats on it get written\nand everything is read back to check it."
    write_card || return 1
    done_step 4
}

s_stick() {
    msg "Step 4: USB stick\n\nplug in a USB stick (8 GB or more) formatted as FAT32.\nthe eMMC backup wants about 4 GB of it."
    mount_stick || return 1
    local free; free=$(df -Pk "$STICK_MNT" | awk 'NR==2 {print $4}')
    [ "$free" -gt 4300000 ] || { msg "only $((free / 1024)) MB free on the stick, need about 4200 MB."; eject_stick; return 1; }
    eject_stick
    done_step 5
}

s_backup() {
    msg "Step 5: back up the eMMC (on the panel)\n\n\
1. put the microSD card back into the panel.\n\
2. plug the USB stick into the panels USB port.\n\
3. power it on. it starts in crustys maintenance mode (\"golden mode\"):\n\
   mght take a while to boot, longer than might feel it should\n\
4. tap \"Back up eMMC to USB stick\" and wait for\n\
   \"backup DONE + verified\" (5-10 min, depends on the stick).\n\
5. tap \"Shut down\" (it saves the logs to the stick first).\n\
6. unplug the panel as soon as the screen goes dark\n\
7. take the card and the stick out and put both into this PC.\n\
Note : If the backup fails due to Checksum errors use a different USB stick\n\
       Make sure to not reboot the panel when swapping out the USB stick!"
    ask "did the backup end with \"backup DONE + verified\"?" || return 1
    done_step 6
}

s_import() {
    step "Step 6: copy the eMMC backup"
    mount_stick || return 1
    local src d list=() items=()
    for d in "$STICK_MNT"/crusty-emmc-backup-*; do [ -d "$d" ] && list+=("$d"); done
    [ ${#list[@]} -gt 0 ] || { eject_stick; die "no crusty-emmc-backup-* folder on the stick"; }
    if [ ${#list[@]} = 1 ]; then
        src=${list[0]}
    else   # several panels share one stick, the folders are named after the panels ethernet MAC (printed on the device)
        for d in "${list[@]}"; do items+=("$d" "$(basename "$d")  $(grep -m1 '^ethaddr=' "$d/info.txt" 2>/dev/null)"); done
        src=$(menu "there is more than one eMMC backup on the stick, which one is of the panel you are setting up?\n\nfolders are named after the panels ethernet MAC address." "${items[@]}") || src=
        [ -n "$src" ] || { eject_stick; return 1; }
    fi
    if [ -d "$BACKUP" ] && ls "$BACKUP"/mmcblk1.part* >/dev/null 2>&1; then
        local keep="$BACKUP.$(date +%Y%m%d-%H%M%S)"
        echo ">> keeping the previous backup as $keep"
        mv "$BACKUP" "$keep"
    fi
    mkdir -p "$BACKUP"
    run cp -v "$src"/* "$BACKUP"/
    eject_stick
    run python3 tools/extract-emmc.py "$BACKUP" work/emmc
    done_step 7
}

build_update() {   # $1 = sd (default) | usb. eMMC update + restore sets, then the card or just the recovery update, then the stick
    run tools/build-su.sh
    run tools/build-dropbear.sh
    run tools/fetch-chromium.sh
    run python3 tools/build-emmc.py
    if [ "${1:-sd}" = usb ]; then
        # the card stays in the panel, golden mode installs the new app + scripts from the stick itself
        run tools/build-apps.sh
        run python3 tools/build-recovery.py
    else
        msg "put the microSD card into the reader (if it isnt in there already).\nits /data gets read first so the settings you made on the panel survive."
        pick_sd || return 1
        unmount_all "$SD"
        run tools/read-data.sh "$SD"
        build_card
        run python3 tools/build-recovery.py
        run tools/flash.sh --incremental out/sdcard-mod.img "$SD"
    fi
    msg "now the USB stick (only the changed parts get written)."
    mount_stick || return 1
    run python3 tools/sync-stick.py "$STICK_MNT" out/crusty-emmc-update out/crusty-emmc-restore out/crusty-recovery-update
    eject_stick
}

s_build_emmc() {
    step "Step 7: build the eMMC update"
    build_update || return 1
    done_step 8
}

s_install() {
    msg "Step 8: install (on the panel)\n\n\
1. put the microSD card back into the panel. it stays there from now on,\n\
   it holds the panels /data.\n\
2. plug the USB stick into the panel.\n\
3. power on. it starts in maintenance mode again.\n\
4. tap \"Update eMMC from USB stick\". it runs a few checks on the\n\
   usb stick first and only writes what differs, then reads it all back.\n\
5. wait for \"install DONE + verified\", then tap\n\
   \"Reboot to the normal system\".\n\n\
if anything goes wrong: More -> \"Restore original eMMC from USB stick\" puts crestrons back."
    ask "did it say \"install DONE + verified\"?" || return 1
    done_step 9
}

s_done() {
    msg "done, BOOM!\n\n\
the panel runs crusty now. long-press the power button for crustys settings.\n\
ssh root@<panel ip> works if you added a key (config/ssh/authorized_keys).\n\n\
your backups:\n\
  $IMG           the original card   (tools/flash.sh $IMG /dev/sdX)\n\
  $BACKUP/   the original eMMC   (\"Restore\" in maintenance mode)\n\
keep both somewhere safe, you WILL want them one day.\n\n\
changed something? ./setup.sh update"
    done_step 10
}

update() {
    [ -d work/emmc/raw ] || die "no extracted eMMC backup yet - run ./setup.sh first"
    check_tools
    local how
    how=$(menu "how does the update get to the panel?" \
        usb "USB stick: golden mode updates itself from the stick, the card stays in the panel" \
        sd "SD card: the card goes into this PC, its /data is read and the card gets written") || exit 0
    [ -n "$how" ] || exit 0
    step "update: rebuild + write what changed"
    build_update "$how" || exit 1
    if [ "$how" = usb ]; then
        msg "on the panel (card and stick in):\n\n\
1. start golden mode (long press power -> crusty -> reboot to golden mode)\n\
2. More -> \"Update recovery from USB stick\", then More -> \"Reboot to golden mode\"\n\
3. only if the eMMC changed too: \"Update eMMC from USB stick\" (it says nothing to do if its current),\n\
   then \"Reboot to the normal system\"\n\n\
the recovery update only exists in golden mode builds that already have it, if yours is older use the SD card once."
    else
        local keep; keep=$(cat "$STATE" 2>/dev/null || echo 0)
        s_install && msg "updated."
        done_step "$keep"   # s_install writes its own step number, an update isnt a step
    fi
}

# ------------------------------------------------------------------ main
[ "${1:-}" = update ] && { update; exit 0; }
STEPS=(s_intro s_open s_dump_sd s_build_sd s_stick s_backup s_import s_build_emmc s_install s_done)
cur=$(cat "$STATE" 2>/dev/null || echo 0)
if [ "$cur" -gt 0 ] && [ "$cur" -lt ${#STEPS[@]} ]; then
    case $(menu "last time you got to step $cur." continue "continue with step $cur" \
                restart "start from the beginning" quit "quit") in
        continue) ;;
        restart) cur=0 ;;
        *) exit 0 ;;
    esac
elif [ "$cur" -ge ${#STEPS[@]} ]; then
    case $(menu "crusty is set up." update "rebuild + update the panel" restart "start over" quit "quit") in
        update) update; exit 0 ;;
        restart) cur=0 ;;
        *) exit 0 ;;
    esac
fi
while [ "$cur" -lt ${#STEPS[@]} ]; do
    if ! ${STEPS[$cur]}; then
        ask "that step didnt finish. try it again?" || { echo "run ./setup.sh to continue later."; exit 1; }
        continue
    fi
    cur=$(cat "$STATE")
done
