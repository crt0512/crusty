#!/system/bin/sh
# root boot hook, started from the top of crestInit.sh at every normal boot (tools/build-emmc.py installs it to /system/bin, nobody runs it by hand).
# keep it short, crestrons boot runs in parallel.
# not made for a second run in the same boot, you would get a second set of its background loops.
LOG=/data/crusty/boot-root.log
mkdir -p /data/crusty
chown 1000:1000 /data/crusty
{
    echo "== $(date) crusty-boot"
    # init only hands "brightness" to system, we want the per-LED switch too
    for f in /sys/class/keypad_led/onoff /sys/class/keypad_led/brightness; do
        [ -e $f ] && chown system:system $f && chmod 0664 $f && echo "  $f -> system"
    done
} >> $LOG 2>&1
chown 1000:1000 $LOG

# su daemon (phh's Superuser), apps still need a grant in the Superuser app.
# turn it off with: touch /data/crusty/config/root_disabled
if [ -x /system/xbin/su ] && [ ! -e /data/crusty/config/root_disabled ]; then
    /system/xbin/su --daemon >> $LOG 2>&1 &
    echo "  su daemon started" >> $LOG
fi


# SSH (Dropbear, keys only) on port 22, but only if keys were put into /data/crusty/ssh/authorized_keys (tools/mod-data.py does that from config/ssh/authorized_keys).
# turn it off with: touch /data/crusty/config/ssh_disabled
# dropbear is picky and wants every folder above the key file root owned and not group/world writable, /data (0771 system) isnt so the keys get copied to /dev/.crusty_ssh at start.
start_ssh() {
    SSH=/data/crusty/ssh
    [ -x /system/xbin/dropbearmulti ] || { echo "  ssh: no /system/xbin/dropbearmulti" >> $LOG; return; }
    [ -s $SSH/authorized_keys ] || { echo "  ssh: no keys in $SSH/authorized_keys" >> $LOG; return; }
    [ -e /data/crusty/config/ssh_disabled ] && { echo "  ssh: disabled" >> $LOG; return; }
    chown -R 0:0 $SSH; chmod 700 $SSH; chmod 600 $SSH/*     # undo crestInits chmod -R 777 /data/* (ewww, gross!)
    [ -s $SSH/host_ed25519 ] || /system/xbin/dropbearmulti dropbearkey -t ed25519 -f $SSH/host_ed25519 >> $LOG 2>&1
    mkdir -p /dev/.crusty_ssh
    chmod 700 /dev/.crusty_ssh
    cat $SSH/authorized_keys > /dev/.crusty_ssh/authorized_keys
    chmod 600 /dev/.crusty_ssh/authorized_keys
    # built without syslog so it logs to stderr anyway (no -E).
    # -e keeps inits environment (BOOTCLASSPATH, ANDROID_ROOT, ...) for the shell, without it am/pm/settings dont work.
    /system/xbin/dropbearmulti dropbear -F -e -s -g -p 22 -D /dev/.crusty_ssh -r $SSH/host_ed25519 \
        -P /dev/.crusty_ssh/pid >> /data/crusty/ssh.log 2>&1 &
    pid=$!
    chmod 644 /data/crusty/ssh.log
    sleep 3
    if kill -0 $pid 2>/dev/null; then
        echo "  $(date +%T) ssh (dropbear) running on port 22, pid $pid" >> $LOG
    else
        echo "  $(date +%T) ssh (dropbear) died right away, see /data/crusty/ssh.log" >> $LOG
    fi
}

# after boot: start the web server (our config, see /system/etc/crusty/lighttpd.conf) and keep crestrons wide open notwork services off: ftp (writable, no login), telnet and ssh (root, empty password allowed, what could possibly go wrong).
# something in crestrons stack starts the latter two later on so we keep checking for the first 15 minutes.
# wait for boot_completed first, crestInit.sh creates /dev/shm only then.
(
    i=0
    while [ "$(getprop sys.boot_completed)" != 1 ] && [ $i -lt 300 ]; do sleep 2; i=$((i + 2)); done
    start lighttpd
    echo "  $(date +%T) lighttpd started" >> $LOG
    i=0
    while [ $i -lt 90 ]; do
        [ $i = 1 ] && start_ssh                # by then crestrons sshd is gone from port 22
        for s in ftpd telnetd telnetd_debug sshd; do
            if [ "$(getprop init.svc.$s)" = running ]; then
                stop $s
                echo "  $(date +%T) stopped $s" >> $LOG
            fi
        done
        sleep 10; i=$((i + 1))
    done
) </dev/null >/dev/null 2>&1 &

# "Reboot to golden mode" in the crusty app: it creates /data/crusty/run/golden-request, we set u-boots boot_retry=10 (what 10 failed boots or the reset button sequence do) and tell the app, which then reboots.
# only after crestrons logBootComplete.sh is done (thats the /dev/shm/LogBootCompleteComplete wait) because it resets boot_retry to 0 and our 10 would be gone.
(
    R=/data/crusty/run
    mkdir -p $R; chown 1000:1000 $R; chmod 0770 $R
    rm -f $R/golden-request $R/golden-status
    i=0
    while [ ! -e /dev/shm/LogBootCompleteComplete ] && [ $i -lt 600 ]; do sleep 2; i=$((i + 2)); done
    while true; do
        if [ -e $R/golden-request ]; then
            rm -f $R/golden-request
            echo "  $(date +%T) reboot to golden mode requested" >> $LOG
            # same values as tools/ubootenv.py golden: DataRecoveryDone=1 and the reformat flags at 0 keep even crestrons original golden scripts from wiping /data
            for kv in "golden_boot_retry 0" "DataRecoveryDone 1" "reformatDataPartition 0" "fwUpgrade 0" \
                      "update_golden_version 0" "boot_retry 10"; do
                /system/bin/fw_setenv $kv >> $LOG 2>&1
            done
            if [ "$(/system/bin/fw_printenv boot_retry 2>/dev/null)" = "boot_retry=10" ]; then
                echo ready > $R/golden-status
                echo "  boot_retry=10 set" >> $LOG
            else
                echo "failed: boot_retry didnt change (see /data/crusty/boot-root.log)" > $R/golden-status
            fi
            chown 1000:1000 $R/golden-status
            sync
        fi
        sleep 1
    done
) </dev/null >/dev/null 2>&1 &
