#!/system/bin/sh
# crustys golden mode ("maintenance") script, replaces /system/bin/crestInit.sh on SD card p2.
# p2 is the /system that crestrons "golden" fallback boots, normal boots use the internal eMMCs /system and never see this file.
# crestrons golden path reformats /data and reflashes the eMMC (how thoughtful), ours does neither, their original is kept next to it as crestInit.sh.crestron.
# nobody runs this by hand: init starts it as root just like the original and it loops forever.
# it feeds the watchdog, resets boot_retry/golden_boot_retry so the next reboot goes back to the normal system and keeps /data/crusty/golden-status up to date (thats what the companions golden banner shows).
# then it waits for requests from that banner, the companion cant do root work itself so its touch buttons write /data/crusty/golden-request:
#   backup   -> copy the whole internal eMMC (only ever read) to a FAT32 USB stick, in 1 GiB pieces + boot0/boot1 + MD5SUMS + info.txt
#   shutdown -> copy the logs to the USB stick (if theres one), sync, power off
#   install  -> write crustys eMMC images from the stick (crusty-emmc-update/), verified
#   restore  -> write the original images back (crusty-emmc-restore/), verified

BB=/system/bin/busybox
DIR=/data/crusty
LOG=$DIR/golden.log
STATUS=$DIR/golden-status
USB=/mnt/crusty_usb

REQ=$DIR/golden-request

mkdir -p $DIR
chown 1000:1000 $DIR      # the companion (system uid) has to be able to drop its requests in here
chmod 0770 $DIR
rm -f $REQ
# careful when rewording status lines: the banner (Golden.java) fishes "(N KiB)", "chunk i/n chunks" and words like "writing" / "checking ... on the stick" out of them for its progress bar.
log() {
    echo "$($BB date '+%m-%d %H:%M:%S') $*" >> $LOG
    echo "$*" > $STATUS
    chmod 644 $LOG $STATUS
}

log "golden mode (crusty maintenance mode) started"
start watchdog
/system/bin/fw_printenv >> $LOG 2>&1
/system/bin/fw_setenv boot_retry 0
/system/bin/fw_setenv golden_boot_retry 0
log "boot_retry reset - the next reboot starts the normal system again"

# ---------------------------------------------------------------- USB stick
# androids vold auto mounts USB sticks (vfat, rw) in golden mode too.
# NEVER mount the same FAT stick a second time: use volds mount if there is one, otherwise mount it ourselves on $USB.
USB_OWN=0
usb_mount() {      # sets MNT (and USB_OWN=1 if we mounted it), returns 1 if no stick
    MNT=""
    while read dev mnt type rest; do
        case "$type:$mnt" in
            vfat:*udisk*|vfat:*media_rw*|vfat:*usb*) MNT=$mnt; USB_OWN=0; return 0 ;;
        esac
    done < /proc/mounts
    for d in /dev/block/sda1 /dev/block/sda /dev/block/sdb1 /dev/block/sdb; do
        [ -b $d ] || continue
        mkdir -p $USB
        if $BB mount -t vfat -o rw $d $USB 2>>$LOG; then MNT=$USB; USB_OWN=1; return 0; fi
    done
    return 1
}

usb_release() {
    sync
    [ $USB_OWN = 1 ] && $BB umount $USB
    USB_OWN=0
}

emmc_kib() {   # size of the whole eMMC in KiB, straight from /proc/partitions so nothing overflows 32 bit
    while read major minor blocks name; do
        [ "$name" = mmcblk1 ] && { echo $blocks; return; }
    done < /proc/partitions
}

save_logs_and_shutdown() {
    if usb_mount; then
        D=$MNT/crusty-logs-$($BB date '+%Y%m%d-%H%M%S')
        mkdir -p $D
        log "saving logs to the USB stick ($MNT) ..."
        cp $LOG $D/ 2>>$LOG
        cp -r $DIR/logs $D/ 2>>$LOG
        dmesg > $D/dmesg.txt 2>&1
        logcat -d -v threadtime > $D/logcat.txt 2>&1
        usb_release
        log "logs saved to ${D##*/} - shutting down"
    else
        log "no USB stick - logs stay on the SD card (/data/crusty) - shutting down"
    fi
    sync
    # lights out right away so it looks off, even if the hardware keeps power
    echo 0 > /sys/class/backlight/aml-bl/brightness 2>/dev/null
    echo 0 > /sys/class/keypad_led/brightness 2>/dev/null
    sleep 1
    # NOT /system/bin/reboot: on this firmware thats a crestron wrapper script that ignores -p, starts gracefulReboot.sh (useless without crestrons stack) and then sleeps forever (premium engineering).
    # so we ask init directly, like androids own shutdown does.
    setprop sys.powerctl shutdown
    sleep 20
    # still here?? then its the kernel level power off (emergency sync + sysrq 'o')
    echo "$($BB date '+%m-%d %H:%M:%S') powerctl did not power off - trying sysrq" >> $LOG
    sync
    echo o > /proc/sysrq-trigger
}

backup() {
    usb_mount || { log "no FAT32 USB stick found - plug one into the USB port and try again"; return; }
    # mksh arithmetic is 32-bit and the eMMC (~3.9e9 bytes) doesnt fit in there, so everything down here counts in KiB/MiB only.
    size_kib=$(emmc_kib)
    case "$size_kib" in ''|*[!0-9]*) log "ERROR: cant read the eMMC size ('$size_kib')"; usb_release; return ;; esac
    size_mib=$((size_kib / 1024))
    # free space: this busybox's stat has -f/-t but no -c and no format support (because why would it).
    # its terse filesystem line has 10 fields: name fsid namelen type bsize blocks bfree bavail files ffree
    # coreutils has 11: ... type bsize fundamental-bsize blocks bfree bavail files ffree
    # check that its all digits before doing math with it, an arithmetic error aborts the whole function in mksh.
    st=$($BB stat -f -t "$MNT" 2>>$LOG)
    echo "$($BB date '+%m-%d %H:%M:%S') stat -f -t: $st" >> $LOG
    set -- $st
    bs=""; avail=""
    if [ $# -eq 10 ]; then bs=$5; avail=$8; elif [ $# -eq 11 ]; then bs=$6; avail=$9; fi
    case "$bs:$avail" in
        *[!0-9:]*|:*|*:) log "free space on the USB stick unknown - trying anyway (a full stick shows up as a dd error)" ;;
        *)  if [ $bs -ge 1024 ]; then free_mib=$((avail / 1024 * (bs / 1024))); else free_mib=$((avail / (1024 * 1024 / bs))); fi
            if [ $free_mib -lt $((size_mib + 16)) ]; then
                log "ERROR: USB stick has only $free_mib MiB free, need $((size_mib + 16)) MiB"
                usb_release
                return
            fi ;;
    esac
    OUT=$MNT/crusty-emmc-backup-$($BB date '+%Y%m%d-%H%M%S')
    mkdir -p $OUT
    log "backing up the eMMC to the USB stick ($MNT) ..."
    {
        echo "crusty eMMC backup"; $BB date
        echo; cat /proc/partitions
        echo; ls -l /dev/block/
        echo; /system/bin/fw_printenv
        echo; dmesg | $BB grep -E 'mmcblk1|emmc|partition'
    } > $OUT/info.txt 2>&1

    ok=1
    for p in mmcblk1boot0 mmcblk1boot1; do
        if [ -b /dev/block/$p ]; then
            log "backup: $p"
            /system/bin/dd if=/dev/block/$p of=$OUT/$p.img bs=1048576 2>>$LOG || ok=0
        fi
    done
    # one sequential read, cut into 1 GiB files by split.
    # no seeking: androids dd has a 32-bit offset so skip= past 2 GiB dies with "Invalid argument" (that broke part 3 once, fun times).
    # meanwhile a second sequential reader checksums the eMMC itself, there is no tee in this busybox but both read the same blocks so the second one mostly hits the page cache.
    chunks=$(( (size_mib + 1023) / 1024 ))
    EMD5=/dev/crusty_emmc.md5
    rm -f $EMD5
    $BB md5sum /dev/block/mmcblk1 > $EMD5 2>>$LOG &
    mpid=$!
    log "backup: copying the eMMC ($size_mib MiB) in $chunks parts of 1 GiB ..."
    /system/bin/dd if=/dev/block/mmcblk1 bs=1048576 2>>$LOG | $BB split -b 1073741824 - $OUT/mmcblk1.part 2>>$LOG
    sync
    # check the total size, in KiB because byte counts dont fit mksh's 32-bit arithmetic
    got_kib=0; parts=0
    for f in $OUT/mmcblk1.part*; do
        [ -f "$f" ] || continue
        set -- $($BB stat -t "$f")   # terse: name size blocks ... (busybox and coreutils agree on this one, what a shocker)
        case "$2" in ''|*[!0-9]*) log "WARNING: cant read the size of ${f##*/}"; continue ;; esac
        got_kib=$((got_kib + $2 / 1024)); parts=$((parts + 1))
    done
    chunks=$parts
    if [ $got_kib -ne $size_kib ]; then
        ok=0
        log "ERROR: copied $got_kib KiB in $parts parts, but the eMMC has $size_kib KiB (stick full or removed?)"
    fi

    log "backup: checksum of the eMMC ..."
    wait $mpid
    set -- $(cat $EMD5 2>/dev/null)
    emmc_md5=$1
    # drop the page cache first or we would verify the backup against RAM instead of the stick
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log "backup: verifying - reading the backup back from the USB stick ..."
    set -- $(cat $OUT/mmcblk1.part* | $BB md5sum)
    stick_md5=$1
    {
        echo "$emmc_md5  mmcblk1.img   (whole eMMC = cat mmcblk1.part* in alphabetical order)"
        (cd $OUT && $BB md5sum mmcblk1boot0.img mmcblk1boot1.img 2>/dev/null)
    } > $OUT/MD5SUMS
    if [ -z "$emmc_md5" ] || [ "$emmc_md5" != "$stick_md5" ]; then
        ok=0
        log "ERROR: verify failed - eMMC md5 '$emmc_md5', backup on the stick '$stick_md5'"
    fi
    echo "eMMC size: $size_kib KiB, md5 $emmc_md5. Restore = concatenate mmcblk1.part* in alphabetical order (aa, ab, ...)." >> $OUT/info.txt
    if [ $chunks -lt 1 ]; then ok=0; log "ERROR: 0 eMMC parts copied (size $size_kib KiB)"; fi
    usb_release
    if [ $ok = 1 ]; then
        log "backup DONE + verified: ${OUT##*/} ($chunks parts, md5 $emmc_md5) - you can unplug the USB stick"
    else
        log "backup FAILED - see $LOG"
    fi
}

# ---------------------------------------------------------------- write image sets to the eMMC
# a set is a folder on the USB stick (made by tools/build-emmc.py) with a MANIFEST, one line per partition:
#   <partition> <image file> <size KiB> <md5 of the image> <allowed current md5s, comma-separated | *>
# images are exactly partition sized so md5(partition) == md5(image) after writing.
# pass 1 checks everything (image on the stick intact, partition size, partition currently in a known state) before anything gets written.
# pass 2 writes, drops caches, reads back and compares.
PLAN=/dev/crusty_plan

md5_of() { set -- $($BB md5sum "$1" 2>>$LOG); echo $1; }

part_kib() {   # size of /dev/block/<name> in KiB (the named Amlogic partitions are < 2 GiB so this fits 32 bit)
    b=$($BB blockdev --getsize64 /dev/block/$1 2>>$LOG)
    case "$b" in ''|*[!0-9]*) echo "" ;; *) echo $((b / 1024)) ;; esac
}

# incremental write: <img>.chunks = "# chunk_kib N" + one md5 per chunk (made by build-emmc.py).
# plan_chunks (pass 1, writes nothing) compares every chunk of the partition with the list and checks each differing chunk ON THE STICK against the list too -> /dev/crusty_todo.<part>
# apply_chunks (pass 2) copies exactly those chunks, so a damaged stick gets refused before the first byte is written.
# offsets stay < 1 GiB (androids dd and its 32-bit offset again), dd works in 64 KiB blocks.
# no conv= anywhere: the panels toolbox dd is built without it ("conv option disabled", thanks for nothing), with seek= it doesnt truncate and the outputs are block devices anyway.
plan_chunks() {   # $1 image, $2 chunk list, $3 device, $4 name -> 0 = ok
    set -- "$1" "$2" "$3" "$4" $(head -1 "$2")
    ck=$7
    case "$ck" in ''|*[!0-9]*) log "ERROR: bad chunk list ${2##*/}"; return 1 ;; esac
    bl=$((ck / 64)); total=$(($(wc -l < "$2") - 1))
    TODO=/dev/crusty_todo.$4
    echo "$ck" > $TODO
    i=0; n=0
    tail -n +2 "$2" > /dev/crusty_chunks
    while read want; do
        [ $((i % 8)) -eq 0 ] && echo "comparing $4: chunk $i/$total chunks, $n differ so far ..." > $STATUS
        set -- "$1" "$2" "$3" "$4" $(/system/bin/dd if=$3 bs=65536 skip=$((i * bl)) count=$bl 2>/dev/null | $BB md5sum)
        if [ "$5" != "$want" ]; then
            set -- "$1" "$2" "$3" "$4" $(/system/bin/dd if=$1 bs=65536 skip=$((i * bl)) count=$bl 2>/dev/null | $BB md5sum)
            if [ "$5" != "$want" ]; then log "ERROR: chunk $i of ${1##*/} on the stick is damaged - nothing was written"; return 1; fi
            echo $i >> $TODO; n=$((n + 1))
        fi
        i=$((i + 1))
    done < /dev/crusty_chunks
    if [ $i -ne $total ]; then log "ERROR: chunk list of ${1##*/} is incomplete"; return 1; fi
    echo "$($BB date '+%m-%d %H:%M:%S') $4: $n of $total chunks ($((n * ck / 1024)) MiB) need writing" >> $LOG
    return 0
}

apply_chunks() {   # $1 image, $2 device, $3 name
    TODO=/dev/crusty_todo.$3
    ck=$(head -1 $TODO); bl=$((ck / 64))
    total=$(($(wc -l < $TODO) - 1)); k=0
    tail -n +2 $TODO > /dev/crusty_chunks
    while read i; do
        echo "writing $3: chunk $k/$total chunks ..." > $STATUS
        if ! /system/bin/dd if=$1 of=$2 bs=65536 skip=$((i * bl)) seek=$((i * bl)) count=$bl 2>>$LOG; then
            log "ERROR: writing chunk $i of $3 failed"; return 1
        fi
        k=$((k + 1))
    done < /dev/crusty_chunks
    log "$3: $total changed chunks ($((total * ck / 1024)) MiB) written"
    return 0
}

write_set() {   # $1 = folder on the stick, $2 = what (install|restore)
    usb_mount || { log "ERROR: no FAT32 USB stick found"; return; }
    S=$MNT/$1
    if [ ! -f $S/MANIFEST ]; then
        log "ERROR: $1/MANIFEST not on the USB stick (copy the folder from out/ first)"
        usb_release; return
    fi
    rm -f $PLAN
    # ---- pass 1: check, write nothing
    while read part file kib md5 allowed; do
        case "$part" in ''|'#'*) continue ;; esac
        dev=/dev/block/$part
        if [ ! -b $dev ]; then log "ERROR: no partition $part"; usb_release; return; fi
        pk=$(part_kib $part)
        if [ "$pk" != "$kib" ]; then log "ERROR: $part is $pk KiB, image is $kib KiB"; usb_release; return; fi
        if [ -f $S/$file.chunks ]; then
            echo "$file: chunk list found - stick data is checked per chunk before writing" >> $LOG
        else
            log "checking $file on the stick ($kib KiB) ..."
            got=$(md5_of $S/$file)
            if [ "$got" != "$md5" ]; then log "ERROR: $file on the stick is damaged (md5 $got)"; usb_release; return; fi
        fi
        log "checking the current $part ($kib KiB) ..."
        cur=$(md5_of $dev)
        if [ "$cur" = "$md5" ]; then
            echo "$part - already up to date" >> $LOG
            continue
        fi
        case "$allowed" in
            '*') ;;
            *)  case ",$allowed," in
                    *",$cur,"*) ;;
                    *) log "ERROR: $part has unknown content ($cur) - refusing to overwrite (restore first?)"
                       usb_release; return ;;
                esac ;;
        esac
        if [ -f $S/$file.chunks ]; then
            plan_chunks $S/$file $S/$file.chunks $dev $part || { usb_release; return; }
        fi
        echo "$part $file $kib $md5" >> $PLAN
    done < $S/MANIFEST
    if [ ! -s $PLAN ]; then log "$2: nothing to do - the eMMC already matches $1"; usb_release; return; fi
    # ---- pass 2: write (only the chunks that differ if the set has a <file>.chunks list) + verify
    ok=1
    while read part file kib md5; do
        dev=/dev/block/$part
        if [ -f $S/$file.chunks ]; then
            apply_chunks $S/$file $dev $part || { ok=0; break; }
        else
            log "writing $part ($kib KiB) ..."
            if ! /system/bin/dd if=$S/$file of=$dev bs=1048576 2>>$LOG; then
                ok=0; log "ERROR: writing $part failed"; break
            fi
        fi
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        log "reading back $part ($kib KiB) ..."
        got=$(md5_of $dev)
        if [ "$got" != "$md5" ]; then ok=0; log "ERROR: $part read back $got, expected $md5"; break; fi
        echo "$($BB date '+%m-%d %H:%M:%S') $part written + verified ($md5)" >> $LOG
    done < $PLAN
    usb_release
    if [ $ok = 1 ]; then
        log "$2 DONE + verified: $(cut_parts) - reboot to the normal system to use it"
    else
        log "$2 FAILED - the eMMC may be half-written: run Restore before rebooting!"
    fi
}

cut_parts() { p=""; while read part rest; do p="$p $part"; done < $PLAN; echo $p; }

# ---------------------------------------------------------------- wait for requests from the banner
idle() {   # doubles as a heartbeat, the ticking clock on the banner shows the script is still alive
    t=$($BB date '+%H:%M:%S')
    if [ -b /dev/block/sda1 ] || [ -b /dev/block/sda ]; then
        echo "ready - USB stick detected - $t" > $STATUS
    else
        echo "ready - no USB stick (plug a FAT32 stick into the USB port for a backup) - $t" > $STATUS
    fi
    chmod 644 $STATUS
}

shown=0
while true; do
    if [ -f $REQ ]; then
        r=$(cat $REQ)
        rm -f $REQ
        echo "$($BB date '+%m-%d %H:%M:%S') request: $r" >> $LOG
        log "request received: $r"
        case "$r" in
            # in a subshell so whatever blows up in there cant kill this loop
            backup) ( backup ) 2>>$LOG || log "ERROR: backup crashed (exit $?) - see golden.log" ;;
            shutdown) save_logs_and_shutdown ;;
            install)  ( write_set crusty-emmc-update install ) 2>>$LOG || log "ERROR: install crashed (exit $?)" ;;
            restore)  ( write_set crusty-emmc-restore restore ) 2>>$LOG || log "ERROR: restore crashed (exit $?)" ;;
            *)      log "unknown request: $r" ;;
        esac
        rm -f $REQ        # taps made while the action was running dont start it again
        shown=30          # keep the result on screen for ~60 s
    fi
    if [ $shown -gt 0 ]; then shown=$((shown - 1)); else idle; fi
    sleep 2
done
