#!/system/bin/sh
# crustys golden mode ("maintenance") script, replaces /system/bin/crestInit.sh on SD card p2.
# p2 is the /system that crestrons "golden" fallback boots, normal boots use the internal eMMCs /system and never see this file.
# crestrons golden path reformats /data and reflashes the eMMC (how thoughtful), ours does neither, their original is kept next to it as crestInit.sh.crestron.
# nobody runs this by hand: init starts it as root just like the original and it loops forever.
# it feeds the watchdog, resets boot_retry/golden_boot_retry so the next reboot goes back to the normal system and keeps /data/crusty/golden-status up to date (thats what the companions golden banner shows).
# then it waits for requests from that banner, the companion cant do root work itself so its touch buttons write /data/crusty/golden-request:
# a request is "<action> [arg]":
#   backup   -> copy the whole internal eMMC (only ever read) to a FAT32 USB stick, in 1 GiB pieces + boot0/boot1 + MD5SUMS + info.txt
#   install [raw] -> write crustys eMMC images from the stick (crusty-emmc-update/), verified
#   restore [raw] -> write the original images back (crusty-emmc-restore/), verified; "raw" = no incremental write, everything gets rewritten
#   savelogs -> copy the logs to the USB stick
#   reboot [stay] -> save the logs, reboot into the normal system ("stay": into golden mode again)
#   shutdown [stay] -> save the logs, power off ("stay": the next boot is golden mode again)
#   netinfo, network, sysinfo, ubootenv -> print stuff into golden.log (the banner shows the tail of it)
#   sshstart, sshstop, sshkeys [from the stick] -> Dropbear in golden mode, same keys as the normal system (/data/crusty/ssh)
#   recovery -> update the recovery itself (this script, the crusty app, ...) from crusty-recovery-update/ on the stick (made by tools/build-recovery.py), takes effect after a reboot
#   verboseon, verboseoff -> serial console + full kernel messages in every boot (u-boot initargs on the SD card)
#   verbosescreenon, verbosescreenoff -> flag file for the crusty apps boot console (kernel log on screen during a normal boot)
#   cleardata, resetcrusty -> clear the apps data / crustys own settings + PIN

BB=/system/bin/busybox
DIR=/data/crusty
LOG=$DIR/golden.log
STATUS=$DIR/golden-status
USB=/mnt/crusty_usb

REQ=$DIR/golden-request
SSHDIR=$DIR/ssh
SSHRUN=/dev/.crusty_ssh        # dropbear wants root owned folders all the way up, /data isnt (same trick as crusty-boot.sh)
SSHFLAG=$DIR/golden-ssh        # exists while our dropbear runs, the banner shows it as a checkbox
VERBFLAG=$DIR/golden-verbose   # exists while the verbose console is in u-boots initargs, same
SYSMNT=/mnt/crusty_emmc_sys

mkdir -p $DIR
chown 1000:1000 $DIR      # the companion (system uid) has to be able to drop its requests in here
chmod 0770 $DIR
rm -f $REQ $SSHFLAG $VERBFLAG
# careful when rewording status lines: the banner (Golden.java) fishes "(N KiB)", "chunk i/n chunks" and words like "writing" / "checking ... on the stick" out of them for its progress bar.
log() {
    echo "$($BB date '+%m-%d %H:%M:%S') $*" >> $LOG
    echo "$*" > $STATUS
    chmod 644 $LOG $STATUS
}

logn() {   # log line without touching the status line
    echo "$($BB date '+%m-%d %H:%M:%S') $*" >> $LOG
    chmod 644 $LOG
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

# the panels clock is 1970 in golden mode, so stick folders are named after the ethernet MAC (the one printed on the panel), 00107FB9C887, not after a date
panel_mac() {
    m=$(/system/bin/fw_printenv ethaddr 2>/dev/null); m=${m#ethaddr=}
    m=$(echo "$m" | tr -d ':' | tr 'a-f' 'A-F')
    if [ -n "$m" ]; then echo $m; else echo unknown; fi
}

next_dir() {   # $1 = name -> $MNT/<name>, or $MNT/<name>-2, -3 ... if that exists already
    nd=$MNT/$1; nn=2
    while [ -e $nd ]; do nd=$MNT/$1-$nn; nn=$((nn + 1)); done
    echo $nd
}

save_logs() {   # returns 1 if there is no stick
    if usb_mount; then
        D=$(next_dir crusty-logs-$(panel_mac))
        mkdir -p $D
        log "saving logs to the USB stick ($MNT) ..."
        cp $LOG $D/ 2>>$LOG
        cp -r $DIR/logs $D/ 2>>$LOG
        dmesg > $D/dmesg.txt 2>&1
        logcat -d -v threadtime > $D/logcat.txt 2>&1
        usb_release
        log "logs saved to ${D##*/}"
        return 0
    fi
    log "no USB stick - logs stay on the SD card (/data/crusty)"
    return 1
}

# next boot is golden mode again: same values as crusty-boot.sh / tools/ubootenv.py golden (the reformat flags at 0 keep even crestrons own scripts from wiping /data)
stay_golden() {
    for kv in "golden_boot_retry 0" "DataRecoveryDone 1" "reformatDataPartition 0" "fwUpgrade 0" "update_golden_version 0" "boot_retry 10"; do
        /system/bin/fw_setenv $kv >> $LOG 2>&1
    done
    [ "$(/system/bin/fw_printenv boot_retry 2>/dev/null)" = "boot_retry=10" ]
}

power_off() {
    # lights out right away so it looks off, even if the hardware keeps power
    echo 0 > /sys/class/backlight/aml-bl/brightness 2>/dev/null
    echo 0 > /sys/class/keypad_led/brightness 2>/dev/null
    sleep 1
    # NOT /system/bin/reboot: on this firmware thats a crestron wrapper script that ignores -p, starts gracefulReboot.sh (useless without crestrons stack) and then sleeps forever (premium engineering).
    # so we ask init directly, like androids own shutdown does.
    setprop sys.powerctl $1
    sleep 20
    # still here?? then its the kernel level way (emergency sync + sysrq 'o' = power off, 'b' = reboot)
    logn "powerctl $1 did not work - trying sysrq"
    sync
    if [ "$1" = reboot ]; then echo b > /proc/sysrq-trigger; else echo o > /proc/sysrq-trigger; fi
}

leave() {   # $1 = shutdown|reboot, $2 = stay -> the next boot is golden mode again
    save_logs
    if [ "$2" = stay ]; then
        if stay_golden; then
            logn "next boot: golden mode again (boot_retry=10)"
        else
            log "ERROR: couldnt set boot_retry=10, so not shutting down - try again (details above)"
            return
        fi
    fi
    log "$1 now ..."
    sync
    power_off $1
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
    OUT=$(next_dir crusty-emmc-backup-$(panel_mac))
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
#   <partition> <image file> <size KiB> <md5 of the image> <allowed current states, comma-separated | *>
# a state is the md5 of the whole partition or p<KiB>:<md5> = md5 of its first KiB, that is the filesystem of a stock ext4 partition (what sits behind the end of the filesystem differs between panels).
# images are exactly partition sized so md5(partition) == md5(image) after writing.
# pass 1 checks everything (image on the stick intact, partition size, partition currently in a known state) before anything gets written.
# pass 2 writes, drops caches, reads back and compares.
PLAN=/dev/crusty_plan

md5_of() { set -- $($BB md5sum "$1" 2>>$LOG); echo $1; }

allowed_ok() {   # $1 device, $2 md5 of the whole device, $3 allowed states -> 0 = a known state
    case ",$3," in *",$2,"*) return 0 ;; esac
    a_dev=$1; a_list=$3
    a_ifs=$IFS; IFS=,; set -- $a_list; IFS=$a_ifs
    for a_e in "$@"; do
        case "$a_e" in
            p[0-9]*:*)
                a_kib=${a_e#p}; a_kib=${a_kib%%:*}
                log "checking the stock filesystem of ${a_dev##*/} ($a_kib KiB) ..."
                set -- $(/system/bin/dd if=$a_dev bs=1024 count=$a_kib 2>/dev/null | $BB md5sum)
                [ "$1" = "${a_e#*:}" ] && return 0 ;;
        esac
    done
    return 1
}

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

# $3 = raw: write every partition completely, no chunk lists and no "already up to date" shortcut (slow, for panels with flaky flash where the incremental compare cant be trusted)
chunked() { [ -f $S/$1.chunks ] && [ "$RAW" != raw ]; }

write_set() {   # $1 = folder on the stick, $2 = what (install|restore), $3 = raw
    RAW=$3
    [ "$RAW" = raw ] && logn "$2: RAW mode - everything gets written"
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
        if chunked $file; then
            echo "$file: chunk list found - stick data is checked per chunk before writing" >> $LOG
        else
            log "checking $file on the stick ($kib KiB) ..."
            got=$(md5_of $S/$file)
            if [ "$got" != "$md5" ]; then log "ERROR: $file on the stick is damaged (md5 $got)"; usb_release; return; fi
        fi
        log "checking the current $part ($kib KiB) ..."
        cur=$(md5_of $dev)
        if [ "$cur" = "$md5" ] && [ "$RAW" != raw ]; then
            echo "$part - already up to date" >> $LOG
            continue
        fi
        case "$allowed" in
            '*') ;;
            *) [ "$cur" = "$md5" ] && allowed='*' ;;
        esac
        case "$allowed" in
            '*') ;;
            *)  if ! allowed_ok $dev $cur "$allowed"; then
                    log "ERROR: $part has unknown content ($cur) - refusing to overwrite (restore first?)"
                    usb_release; return
                fi ;;
        esac
        if chunked $file; then
            plan_chunks $S/$file $S/$file.chunks $dev $part || { usb_release; return; }
        fi
        echo "$part $file $kib $md5" >> $PLAN
    done < $S/MANIFEST
    if [ ! -s $PLAN ]; then log "$2: nothing to do - the eMMC already matches $1"; usb_release; return; fi
    # ---- pass 2: write (only the chunks that differ if the set has a <file>.chunks list) + verify
    ok=1
    while read part file kib md5; do
        dev=/dev/block/$part
        if chunked $file; then
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

# ---------------------------------------------------------------- network, ssh and other debugging helpers
# everything these print goes into golden.log, thats what the banners log panel shows
eth_ip() {   # first IPv4 address of eth0, empty if none
    set -- $(ip -o -4 addr show eth0 2>/dev/null)
    while [ $# -gt 0 ]; do
        if [ "$1" = inet ]; then echo ${2%%/*}; return; fi
        shift
    done
}

net_up() {
    # crestInit.sh does this at every normal boot and ours doesnt: AndroidEthInit brings up eth0 (static or DHCP, whatever the panel was set to)
    log "starting the network (AndroidEthInit) ..."
    if [ -x /system/bin/AndroidEthInit ]; then
        /system/bin/AndroidEthInit >> $LOG 2>&1
    else
        logn "no /system/bin/AndroidEthInit"
    fi
    i=0
    while [ $i -lt 20 ] && [ -z "$(eth_ip)" ]; do
        [ $i = 8 ] && { logn "no address yet, starting dhcpcd_lan"; ifconfig eth0 up >> $LOG 2>&1; start dhcpcd_lan; }
        sleep 1; i=$((i + 1))
    done
    ip=$(eth_ip)
    if [ -n "$ip" ]; then log "network up: eth0 $ip"; else log "ERROR: eth0 has no IPv4 address (cable? DHCP?) - see Network info"; fi
}

netinfo() {
    log "network info (see the log below)"
    {
        for n in /sys/class/net/*; do
            echo "${n##*/}: $(cat $n/operstate 2>/dev/null) carrier $(cat $n/carrier 2>/dev/null) mac $(cat $n/address 2>/dev/null)"
        done
        ip -o -4 addr 2>&1
        ip route 2>&1
        echo "dns: $(getprop net.dns1) $(getprop net.dns2)"
    } >> $LOG 2>&1
}

sysinfo() {
    log "system info (see the log below)"
    {
        echo "kernel: $(cat /proc/version | cut -c1-110)"
        echo "uptime: $(uptime)"
        echo "cmdline: $(cat /proc/cmdline | cut -c1-180)"
        free 2>&1 | head -3
        df /data /system /cache 2>&1
        echo "usb: $(lsusb 2>&1 | tr '\n' ';' | cut -c1-200)"
        grep -E 'mmcblk|sd[a-z]' /proc/mounts
    } >> $LOG 2>&1
}

ubootenv() {
    log "u-boot environment (see the log below)"
    /system/bin/fw_printenv 2>&1 | cut -c1-160 >> $LOG
}

dropbear_bin() {   # prints the dropbearmulti to use: p2s own (tools/mod-golden.py puts it there), else the one on the eMMCs /system (mounted read only)
    if [ -x /system/xbin/dropbearmulti ]; then echo /system/xbin/dropbearmulti; return 0; fi
    mkdir -p $SYSMNT
    if [ ! -x $SYSMNT/xbin/dropbearmulti ]; then $BB mount -t ext4 -o ro /dev/block/system $SYSMNT 2>>$LOG; fi
    if [ -x $SYSMNT/xbin/dropbearmulti ]; then echo $SYSMNT/xbin/dropbearmulti; return 0; fi
    return 1
}

ssh_running() { [ -f $SSHRUN/pid ] && kill -0 "$(cat $SSHRUN/pid)" 2>/dev/null; }

ssh_start() {
    if ssh_running; then log "ssh is already running"; return; fi
    DB=$(dropbear_bin) || { log "ERROR: no dropbear here (not on this /system, not on the eMMCs) - the crusty eMMC update brings it"; return; }
    if [ ! -s $SSHDIR/authorized_keys ]; then
        log "ERROR: no ssh keys in $SSHDIR/authorized_keys - put authorized_keys on the stick and use Import SSH keys"
        return
    fi
    [ -n "$(eth_ip)" ] || net_up
    chown -R 0:0 $SSHDIR; chmod 700 $SSHDIR; chmod 600 $SSHDIR/*
    [ -s $SSHDIR/host_ed25519 ] || $DB dropbearkey -t ed25519 -f $SSHDIR/host_ed25519 >> $LOG 2>&1
    mkdir -p $SSHRUN; chmod 700 $SSHRUN
    cat $SSHDIR/authorized_keys > $SSHRUN/authorized_keys
    chmod 600 $SSHRUN/authorized_keys
    rm -f $SSHRUN/pid
    $DB dropbear -F -e -s -g -p 22 -D $SSHRUN -r $SSHDIR/host_ed25519 -P $SSHRUN/pid >> $DIR/ssh.log 2>&1 &
    sleep 2
    if ssh_running; then
        echo on > $SSHFLAG; chmod 644 $SSHFLAG $DIR/ssh.log
        ip=$(eth_ip)
        log "ssh is running: ssh root@${ip:-<no address yet>}"
    else
        log "ERROR: dropbear died right away, see $DIR/ssh.log"
    fi
}

ssh_stop() {
    ssh_running && kill "$(cat $SSHRUN/pid)" 2>>$LOG
    rm -f $SSHFLAG
    log "ssh stopped"
}

ssh_import_keys() {   # adds the keys of authorized_keys and *.pub files in the root of the stick, nothing gets replaced
    usb_mount || { log "ERROR: no FAT32 USB stick found"; return; }
    mkdir -p $SSHDIR; touch $SSHDIR/authorized_keys
    n=0; seen=0
    for f in $MNT/authorized_keys $MNT/*.pub; do
        [ -f "$f" ] || continue
        seen=$((seen + 1))
        while read -r line; do
            case "$line" in ssh-*|ecdsa-*|sk-*) ;; *) continue ;; esac
            if ! grep -qxF "$line" $SSHDIR/authorized_keys; then echo "$line" >> $SSHDIR/authorized_keys; n=$((n + 1)); fi
        done < "$f"
    done
    usb_release
    chown -R 0:0 $SSHDIR; chmod 700 $SSHDIR; chmod 600 $SSHDIR/*
    if [ $seen = 0 ]; then
        log "ERROR: no authorized_keys or *.pub file in the root of the USB stick"
    else
        log "ssh keys: $n new key(s) added, $(wc -l < $SSHDIR/authorized_keys) in total (they work in the normal system too)"
        ssh_running && log "restart ssh to use them"
    fi
}

# clears what apps stored, not the apps themselves: /data/data/<pkg>/* except the lib link, and not crusty or the providers (settings.db lives there)
clear_userdata() {
    log "clearing the apps' data ..."
    n=0
    for d in /data/data/*; do
        [ -d "$d" ] || continue
        case "${d##*/}" in dev.crusty.companion|com.android.providers.*) continue ;; esac
        for f in "$d"/* "$d"/.[!.]*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            [ "${f##*/}" = lib ] && continue
            rm -rf "$f"
        done
        n=$((n + 1))
    done
    sync
    log "data of $n apps cleared"
}

reset_crusty() {
    rm -rf $DIR/config /data/data/dev.crusty.companion/shared_prefs
    sync
    log "crusty settings and PIN reset (the banner keeps running, the normal system starts fresh)"
}

# ---------------------------------------------------------------- update the recovery from the stick
# crusty-recovery-update/ on the stick (tools/build-recovery.py) has a MANIFEST, one line per file:
#   <destination> <file on the stick> <md5> <mode> <uid:gid>
# pass 1 checks every file on the stick (md5, shell scripts also get a syntax check) before anything is touched.
# pass 2 copies each file next to its destination as <dest>.new, drops the caches and compares it, and only then renames it over the old one.
# the rename keeps the running script (and the running crusty app) on their old inode until the next boot, overwriting a running shell script in place makes sh read garbage (no bueno).
update_recovery() {
    usb_mount || { log "ERROR: no FAT32 USB stick found"; return; }
    S=$MNT/crusty-recovery-update
    if [ ! -f $S/MANIFEST ]; then
        log "ERROR: crusty-recovery-update/MANIFEST not on the USB stick (run tools/build-recovery.py and sync it)"
        usb_release; return
    fi
    n=0
    while read dest file md5 mode owner; do
        case "$dest" in ''|'#'*) continue ;; esac
        log "checking $file ..."
        got=$(md5_of $S/$file)
        if [ "$got" != "$md5" ]; then log "ERROR: $file on the stick is damaged (md5 $got) - nothing was changed"; usb_release; return; fi
        case "$dest" in
            *.sh|*/app_process) if ! /system/bin/sh -n $S/$file 2>>$LOG; then log "ERROR: $file has a syntax error - nothing was changed"; usb_release; return; fi ;;
        esac
        n=$((n + 1))
    done < $S/MANIFEST
    if [ $n = 0 ]; then log "ERROR: the MANIFEST on the stick is empty"; usb_release; return; fi

    was_ro=0
    while read d m t o r; do
        if [ "$m" = /system ]; then case ",$o," in *,ro,*) was_ro=1 ;; esac; fi
    done < /proc/mounts
    [ $was_ro = 1 ] && $BB mount -o remount,rw /system 2>>$LOG
    ok=1; done_n=0
    while read dest file md5 mode owner; do
        case "$dest" in ''|'#'*) continue ;; esac
        if [ "$(md5_of $dest)" = "$md5" ]; then echo "$dest - already up to date" >> $LOG; continue; fi
        log "installing $dest ..."
        mkdir -p ${dest%/*}
        rm -f $dest.new
        cp $S/$file $dest.new 2>>$LOG && chmod $mode $dest.new
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        if [ "$(md5_of $dest.new)" != "$md5" ]; then
            log "ERROR: $dest.new doesnt match after copying - not installed"
            rm -f $dest.new; ok=0; break
        fi
        chown $owner $dest.new 2>>$LOG
        case "$dest" in
            /system/*) chcon u:object_r:system_file:s0 $dest.new 2>>$LOG ;;
            /data/app/*) chcon u:object_r:apk_data_file:s0 $dest.new 2>>$LOG ;;
        esac
        if ! mv $dest.new $dest 2>>$LOG; then log "ERROR: couldnt replace $dest"; rm -f $dest.new; ok=0; break; fi
        done_n=$((done_n + 1))
    done < $S/MANIFEST
    sync
    [ $was_ro = 1 ] && $BB mount -o remount,ro /system 2>>$LOG
    usb_release
    if [ $ok = 1 ]; then
        log "recovery update DONE + verified: $done_n of $n file(s) replaced - use \"Reboot to golden mode\" to run it"
    else
        log "recovery update FAILED - see above (the old files are still in place unless it says otherwise)"
    fi
}

# verbose boot: u-boots initargs has a literal ${bootargs_console} in it that u-boot never expands (it ends up as a junk word on the kernel command line), and that is where a console belongs.
# so "on" swaps that word for a real serial console + ignore_loglevel (the kernel prints everything on the UART pads, there is no framebuffer console on this kernel), "off" swaps it back.
# the env lives on the SD card (fw_env.config), so this holds for normal boots as well until it gets switched off.
VERBOSE_ARGS="console=ttyS0,115200n8 ignore_loglevel"

initargs_get() { cur=$(/system/bin/fw_printenv initargs 2>/dev/null); cur=${cur#initargs=}; }

verbose_flag() {   # sync the flag file (for the banners checkbox) with the env
    initargs_get
    case "$cur" in
        *ignore_loglevel*) echo on > $VERBFLAG; chmod 644 $VERBFLAG ;;
        *) rm -f $VERBFLAG ;;
    esac
}

verbose() {   # $1 = on|off
    initargs_get
    [ -n "$cur" ] || { log "ERROR: cant read initargs from the u-boot env"; return; }
    if [ "$1" = on ]; then
        case "$cur" in *ignore_loglevel*) verbose_flag; log "verbose boot is already on"; return ;; esac
        new=$(echo "$cur" | sed 's|${bootargs_console}|'"$VERBOSE_ARGS"'|')
    else
        case "$cur" in *ignore_loglevel*) ;; *) verbose_flag; log "verbose boot is already off"; return ;; esac
        new=$(echo "$cur" | sed 's|'"$VERBOSE_ARGS"'|${bootargs_console}|')
    fi
    if [ "$new" = "$cur" ]; then log "ERROR: initargs has no \${bootargs_console} to work with, left it alone"; return; fi
    /system/bin/fw_setenv initargs "$new" >> $LOG 2>&1
    initargs_get
    if [ "$cur" = "$new" ]; then
        verbose_flag
        if [ "$1" = on ]; then log "verbose boot on: serial console 115200n8 from the next boot on"; else log "verbose boot off"; fi
    else
        log "ERROR: u-boot env didnt take the new initargs (see above), nothing changed"
    fi
}

# the flag file BootConsole.java looks for, with it the app yoinks the screen during a normal boot and yaps the kernel log all over it
verbose_screen() {   # $1 = on|off
    F=$DIR/config/verbose_screen
    if [ "$1" = on ]; then
        mkdir -p $DIR/config
        touch $F
        chown 1000:1000 $F; chmod 666 $F
        log "verbose boot on screen: on (normal boots, until Android has booted)"
    else
        rm -f $F
        log "verbose boot on screen: off"
    fi
}

# ---------------------------------------------------------------- wait for requests from the banner
idle() {   # doubles as a heartbeat, the ticking clock on the banner shows the script is still alive
    [ -f $SSHFLAG ] && ! ssh_running && rm -f $SSHFLAG
    t=$($BB date '+%H:%M:%S')
    if [ -b /dev/block/sda1 ] || [ -b /dev/block/sda ]; then
        echo "ready - USB stick detected - $t" > $STATUS
    else
        echo "ready - no USB stick (plug a FAT32 stick into the USB port for a backup) - $t" > $STATUS
    fi
    chmod 644 $STATUS
}

verbose_flag
shown=0
while true; do
    if [ -f $REQ ]; then
        r=$(cat $REQ)
        rm -f $REQ
        echo "$($BB date '+%m-%d %H:%M:%S') request: $r" >> $LOG
        log "request received: $r"
        set -- $r
        act=$1; arg=$2
        case "$act" in
            # in a subshell so whatever blows up in there cant kill this loop
            backup)   ( backup ) 2>>$LOG || log "ERROR: backup crashed (exit $?) - see golden.log" ;;
            install)  ( write_set crusty-emmc-update install $arg ) 2>>$LOG || log "ERROR: install crashed (exit $?)" ;;
            restore)  ( write_set crusty-emmc-restore restore $arg ) 2>>$LOG || log "ERROR: restore crashed (exit $?)" ;;
            savelogs) ( save_logs ) 2>>$LOG ;;
            shutdown) ( leave shutdown $arg ) 2>>$LOG ;;
            reboot)   ( leave reboot $arg ) 2>>$LOG ;;
            recovery) ( update_recovery ) 2>>$LOG || log "ERROR: recovery update crashed (exit $?)" ;;
            netinfo)  ( netinfo ) 2>>$LOG ;;
            network)  ( net_up; netinfo ) 2>>$LOG ;;
            sysinfo)  ( sysinfo ) 2>>$LOG ;;
            ubootenv) ( ubootenv ) 2>>$LOG ;;
            sshstart) ( ssh_start ) 2>>$LOG ;;
            sshstop)  ( ssh_stop ) 2>>$LOG ;;
            sshkeys)  ( ssh_import_keys ) 2>>$LOG ;;
            verbosescreenon)  ( verbose_screen on ) 2>>$LOG ;;
            verbosescreenoff) ( verbose_screen off ) 2>>$LOG ;;
            verboseon)  ( verbose on ) 2>>$LOG ;;
            verboseoff) ( verbose off ) 2>>$LOG ;;
            cleardata)   ( clear_userdata ) 2>>$LOG ;;
            resetcrusty) ( reset_crusty ) 2>>$LOG ;;
            *)      log "unknown request: $r" ;;
        esac
        rm -f $REQ        # taps made while the action was running dont start it again
        shown=30          # keep the result on screen for ~60 s
    fi
    if [ $shown -gt 0 ]; then shown=$((shown - 1)); else idle; fi
    sleep 2
done
