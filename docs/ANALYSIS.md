# TSW-760 SD card analysis

Everything I found out about this thing, in roughly the order I found it. Its a research log so some early sections get corrected further down, read on before believing anything as fact.

Source: `img/sdcard.img` (3,980,394,496 bytes). Firmware `TSW-760 v3.002.1061`, built 2024-06-04.

## SoC / platform

|                |                                                                                                                 |
|----------------|-----------------------------------------------------------------------------------------------------------------|
| SoC            | **Amlogic Meson8 / S802-class "M8M2"** (`AMLOGIC,8726_M8M2`), 4x Cortex-A9, PL310 L2                            |
| RAM            | 2 GB (`linux,total-memory = 0x7fe00000`)                                                                        |
| Board codename | `yushan_one` (Jabil-built, see `jabil_factory` env), DTB variant picked by u-boot env `aml_dt=yushan_one_7inch` |
| Display        | 1024x600 LVDS panel on the 7" (`lcdsize=7inch`, `lcmsupplier=truly`); backlight via I2C LP8556 / MP3309C        |
| Ethernet       | Meson internal MAC (`ethernet@0xc9410000`)                                                                      |
| Other DT nodes | WiFi/BT nodes present, camera (`aml_cams`), I2C touch (`amlogic,aml_touch`), HDMI TX, audio codec               |
| Bootloader     | Amlogic BL1 -> u-boot (Amlogic "Lollipop" BSP tree), `crestron_uboot_version=1.00.12`                           |
| Kernel         | **Linux 3.10.33** (Amlogic BSP), uImage, LZO compressed, load 0x00208000                                        |
| Android        | **5.1.1 Lollipop** (LMY47V, SDK 22), `ro.board.platform=meson8`, signed with **test-keys**                      |

## Storage: SD card + internal eMMC (important)

The panel has **two** storage devices, which took us a while to notice. The kernel log on p8 (`/logs/kernelLog`) shows `mmcblk0` = this 4 GB SD card and `mmcblk1` = a 4 GB **internal eMMC** (H4G2a) with an Amlogic partition table:

| eMMC part  | offset     | size                                            |
|------------|------------|-------------------------------------------------|
| bootloader | 0x0        | 4 MiB                                           |
| reserved   | 0x2400000  | 64 MiB                                          |
| cache      | 0x6c00000  | 512 MiB                                         |
| logo       | 0x27400000 | 48 MiB (the u-boot splash lives here)           |
| recovery   | 0x2ac00000 | 32 MiB                                          |
| misc       | 0x2d400000 | 32 MiB                                          |
| boot       | 0x2fc00000 | 32 MiB                                          |
| **system** | 0x32400000 | 1 GiB, mounted as `/system` in normal operation |
| data       | 0x72c00000 | ~1.8 GiB (unused)                               |

In **normal operation** `/system` is the eMMC (`mmcblk1p8`). The SD card provides `/sdcard` (p5), **`/data` (p6)**, `/cache` (p7) and `/logs` (p8).
SD p1 (`boot.img`) and p2 (`/system`) are crestrons **"golden" fallback** system: `crestInit.sh` treats "`/system` is mmcblk0p2" as "we are in golden" and then reformats/restores data.
The golden and eMMC systems are the same build (3.002.1061) and `/data/system/packages.xml` lists the same apps, so p2 is a good stand-in for analysis.

What that means for us:
- Changing SD p2 only affects golden mode. To change the live system offline, change **`/data` (p6)**.
- Removing the crestron *native daemons* (init services) would need writes to the eMMC (`boot`/`system`), which cant be done from this card image alone.

## Card layout

| Region     | Sectors (start / size) | Size    | Contents                                                                                 |
|------------|------------------------|---------|------------------------------------------------------------------------------------------|
| 0-1 MiB    | 0 / 2048               | 1 MiB   | MBR + Amlogic BL1/SPL + u-boot (raw, SD-boot). MBR code area holds `M3HHREV0`            |
| p3         | 2048 / 2048            | 1 MiB   | **u-boot environment** (plain text after a 4-byte CRC). See `work/raw/env.txt`           |
| 2-40 MiB   | -                      | 38 MiB  | Mostly empty; stale FAT boot sector at 4 MiB                                             |
| p1         | 81920 / 81920          | 40 MiB  | **FAT16**, holds `boot.img` (kernel + ramdisk + multi-DTB)                               |
| 80-101 MiB | -                      |         | empty                                                                                    |
| p2         | 206849 / 1638400       | 800 MiB | golden `/system` ext4 (fallback only, see above)                                         |
| p4         | 1845249                |         | extended partition                                                                       |
| p5         | 1847297 / 3055616      | 1.5 GiB | `/mnt/sdcard` ext4 (label `sdcard`). Contains more boot images (firmware update staging) |
| p6         | 4904961 / 1024000      | 500 MiB | **live `/data`** (no SELinux labels on files)                                            |
| p7         | 5931009 / 204800       | 100 MiB | `/cache` ext4                                                                            |
| p8         | 6137857 / 614400       | 300 MiB | `/logs` ext4 (needs journal recovery = was mounted when dumped)                          |

See the odd (+1) start sectors of p2/p5-p8? Thats how Amlogics SD card burner lays them out (because of course it does), so KEEP THEM as they are.

## Boot chain

1. SoC ROM loads BL1 from the SD card (`1st tSD/fSD on SDIO ...`), which decompresses (UCL) and starts u-boot.
2. u-boot `preboot` -> `prepare` shows the logo (`imgread pic logo bootup`), then `storeboot` -> `bootcmd=mmcinfo;imgread kernel boot ${loadaddr};bootm;`
3. `boot.img` from p1: Android v0 boot image, page 2048
   - kernel: uImage (Linux-3.10.33, LZO)
   - ramdisk: gzip cpio (Android init, `fstab.amlogic`, `init.crestron.rc`)
   - "second": **AML_ multi-DTB v2** with 6 variants: `yushan_one_{5,7,10}inch` and `old{5,7,10}inch`
4. The kernel cmdline is built entirely by u-boot (`initargs` + `storeargs`). The boot.img cmdline field is empty.
5. Android mounts `mmcblk0p2/5/6/7/8` from `fstab.amlogic`, then crestrons services (`init.crestron.rc`, `crestInit.sh`) bring up the crestron stack.

Resolved: the boot/logo partitions are on the internal eMMC (see above). The original note, kept for the record: `imgread kernel boot` / `imgread pic logo` reference Amlogic named partitions, but there is no raw `logo` or `boot` area on the card. crestrons u-boot seems to resolve `boot` into p1's FAT `boot.img`. **The u-boot logo was not found.** It may be compiled into u-boot or missing, in which case the screen stays blank until Android. Needs a serial console to confirm (`console_on=console=ttyS0,115200n8` exists in env; UART_AO pads on the board).

## Boot splash

Two stages after u-boot:

- **Android boot animation**: `/system/media/bootanimation.zip` (one static PNG, `desc.txt` = `402 49 30`). Variants exist for portrait/5"/10"/fw-update. Easy to replace: standard Android bootanimation format, written into p2 with `debugfs -w`.
- **Crestron overlay**: `/system/bin/overlayBootAnimation` draws `/system/media/crestronbootimage{2,3}.data` (raw framebuffer data, 798,720 bytes; pixel format not yet decoded).

## Alternative OS feasibility (first take)

- **Newer Android**: Meson8 never got vendor support beyond 5.1 (kernel 3.10). Anything newer means a community port on the BSP kernel. Likely alot of effort for little gain.
- **Debian / mainline Linux**: Mainline Linux does support Meson8/Meson8m2 (`arch/arm/boot/dts/amlogic/meson8m2-*.dts`, work by Martin Blumenstingl et al.). CPU, UART, MMC, USB, ethernet and SMP work there. **Display/LVDS and the panel's touch controller are the big unknowns.** The Meson8 VPU/HDMI/LCD drivers are not in mainline. A realistic first milestone:
  1. Get serial console on the board.
  2. Boot a mainline zImage + `meson8m2-*.dtb` (adapted from `yushan_one_7inch.dts`) by replacing `boot.img` in p1. The existing u-boot can `bootm` a uImage + ramdisk.
  3. Debian armhf rootfs on p2 or p5.

  Headless (ethernet + serial) is very likely doable. A working screen is the hard part.
- **TWRP**: There is no `recovery` image on the card. A TWRP build for Amlogic M8 / kernel 3.10 could be booted from p1 in place of `boot.img` (keep a backup). Since the card can simply be re-imaged, a recovery is less important than on eMMC devices.

## Tooling in this repo

| Script                | What it does                                                                                                   |
|-----------------------|----------------------------------------------------------------------------------------------------------------|
| `tools/extract.sh`    | Splits the dump into `work/` (partitions, env, FAT contents, unpacked boot.img, DTBs, /system). No root needed |
| `tools/bootimg.py`    | Unpack/repack the Android boot image (round-trips byte-identical)                                              |
| `tools/dtb.py`        | Split the AML_ multi-DTB and dump a DTB as text (no `dtc` needed)                                              |
| `tools/uimage.py`     | Show/strip the uImage header                                                                                   |
| `tools/pack.sh`       | Rebuild a full card image from the original + modified `work/raw/pN.img` (unmodified -> byte-identical)        |
| `tools/build-apps.sh` | Build platform-signed AOSP Settings + Launcher2 and the patched SystemUI                                       |
| `tools/patches.py`    | Smali patches used by build-apps.sh (each one asserts it matched)                                              |
| `tools/apicheck.py`   | Find framework fields/methods an app uses that the panel's boot classpath lacks                                |
| `tools/mod-data.py`   | Offline on the /data image (p6): install APKs / system-app updates, disable packages, keylayouts               |
| `tools/flash.sh`      | Write the image to an SD card, with checks for removable/mounted/size and a confirmation prompt                |

Editing p1 (FAT) without root needs `mtools` (`mcopy`), which is not installed yet.

## Signing keys

The platform certificate (framework-res.apk, CrestronHome, SystemUI, ...) is the **public AOSP test key** (lol): sha256 `C8:A2:E9:BC:CF:59:7C:2F:B6:DC:66:BE:E2:93:FC:13:F2:FC:47:EC:77:BC:6B:2B:0D:52:C1:1F:51:19:2A:B8`, identical to `build/target/product/security/platform.x509.pem` in AOSP 5.1.1_r6.
So anything signed with AOSP's `platform.pk8` is treated as a platform app (e.g. Settings with `sharedUserId=android.uid.system`). Very prem for us, pretty embarassing for a shipping product.

## Debloat + AOSP Settings/Launcher (offline, via /data)

1. `tools/build-apps.sh` takes Settings + Launcher2 from Google's API 22 ARM emulator image (AOSP 5.1.1, test-keys). Those are odexed and ART "quickens" the embedded dex, so the original signature cant be restored. They get deodexed with SmaliEx `oat2dex`, patched (`tools/patches.py`) and re-signed with the AOSP platform key -> `work/apps/*.apk`. It also builds the patched SystemUI (below).
2. `tools/mod-data.py` writes them to `/data/app/<pkg>-1/base.apk` on p6. Android 5.1's PackageManager picks up unknown packages there at boot (`SCAN_REQUIRE_KNOWN` only rejects *known* packages at a different path). It also disables the packages in `config/disable-packages.txt` via `package-restrictions.xml` (`enabled="2"`, like `pm disable`). With `com.crestron.home` disabled, Launcher2 is the only HOME app.
3. `tools/pack.sh` -> `out/sdcard-mod.img`, `tools/flash.sh` -> spare card.

The p6 dump has pre-existing fsck warnings (free counts, one orphan inode) because it was taken from a running panel. They are harmless, Android runs e2fsck on it at boot anyway.

## Compatibility of the AOSP apps with the panel framework

The emulator image is LMY48X (Aug 2015). The panel is LMY47V (Apr 2015) plus Amlogic changes. Two differences matter:

- **API**: `tools/apicheck.py` resolves every framework field/method reference against the panel's full BOOTCLASSPATH (baksmali'd into `work/smali/boot`). Settings had exactly one miss: `Build.VERSION.SECURITY_PATCH` (added in LMY48). That was the "About phone" crash (`NoSuchFieldError`). Its patched to an empty string so the About screen hides that entry. Launcher2: no misses.
- **Private framework resource IDs**: Amlogic added 75 resources to framework-res, which shifted 88 private IDs. Those IDs are compiled into the apps as constants so `patches.py` remaps them (only `config_mobile_hotspot_provision_app` in TetherSettings was actually used).

## Keyguard removed from the framework -> HOME crashes

The panel's `PhoneWindowManager.systemReady()` is patched (Crestron/Amlogic) to set `mKeyguardDelegate = null` instead of creating a `KeyguardServiceDelegate`. There is no keyguard at all.
Stock code null-checks it almost everywhere, but **not in `launchHomeFromHotKey()`**: every KEYCODE_HOME (nav bar or side button) throws `NullPointerException ... KeyguardServiceDelegate.isInputRestricted()` in `interceptKeyBeforeDispatching` and gets dropped (found in the crusty logcat).
Starting the HOME intent directly works. `android.policy.jar` is on the eMMC so the key gets routed around it:
- nav bar Home: `KeyButtonView.sendEvent` patched (patches.py) to call the injected `com.android.systemui.crusty.CrustyHome.goHome()` (close system dialogs + start HOME) instead of injecting KEYCODE_HOME. Injected keys dont pass accessibility key filters, so this has to live in SystemUI.
- side Home button: consumed by the companion's key-filtering accessibility service before PWM sees it.

(`lockscreen.disabled=1` in settings.ini is harmless but irrelevant.)

## Screen off / power

Android's screen-off (power key or timeout) runs the kernel **early-suspend chain, which includes `ft5x0x_ts_suspend` -> touch controller held in reset (`gpio_reset(65)=0`)**.
The side buttons are touch zones of that controller, so nothing can wake the panel ("eternal sleep"; pressing twice quickly works because the second press lands before the chain finishes).
An earlier note here said the driver has no suspend hook. That was wrong, it registers through early-suspend.
So: no POWER/SLEEP keycodes, `screen_off_timeout` pinned to max (settings.ini + companion enforces it), and "screen off" = companion `Blanker`: `/sys/class/backlight/aml-bl/brightness` (chowned to system) -> 0, LEDs -> 0, black TYPE_SYSTEM_ERROR overlay that swallows the first touch.

## Status bar / notification shade / nav bar

- crestrons SystemUI has `config_statusBarComponent = com.android.systemui.statusbar.tv.TvStatusBar`, the empty Android TV status bar (an Amlogic set-top-box default). Thats why there is no status bar, shade or quick settings, even though the full `PhoneStatusBar` code and layouts are still in the APK.
- Nav bar: `config_showNavigationBar=false` and `qemu.hw.mainkeys=1` (build.prop, eMMC, read-only), so `hasNavigationBar()` is false. PhoneWindowManager's `beginLayoutLw` lays out a nav bar window whenever one exists, though.
- Fix (`patches.py SystemUI`): `TvStatusBar` becomes a plain subclass of `PhoneStatusBar`, so no resource edit is needed. With `NAVBAR=1` (default) PhoneStatusBar creates the nav bar regardless of `hasNavigationBar()`. Side effects of the forced nav bar: the window manager still thinks there is no nav bar for `getNonDecorDisplay*` (the app config size ignores it) and `canHideNavigationBar()`, so fullscreen/immersive apps cant hide it.
- Installed as an **update of the system app**: `/data/app/com.android.systemui-1/base.apk` + `packages.xml` (`<updated-package>` for /system/priv-app/SystemUI, live `<package>` codePath in /data, `FLAG_UPDATED_SYSTEM_APP`). PMS 5.1 then skips the /system copy (same versionCode) and keeps the /data one privileged. Signed with the platform key = same cert as the original.

## Side buttons

The 5 capacitive buttons (labels top->bottom: **power, home, lamp, up, down**) are **touch-key zones of the ft5x06 touch controller** (DT `tpkey_1..5`, x=1060..1130, outside the 1024 px screen). The kernel emits Linux scancodes 158, 102, 113, 115, 114 (KEY_BACK/HOME/MUTE/VOLUMEUP/VOLUMEDOWN). Crestron **removed these from the key layouts**, so Android drops them.

The ft5x06 reports **vendor 0001 / product 0001**, like `aml_keypad` (IR remote), `gpio_keypad` and `rn5t618_pmu` (EventHub "New device" lines in the original /logs/sysLog). All of them use `/system/usr/keylayout/Vendor_0001_Product_0001.kl`, which has these keys commented out. A name-based `ft5x06.kl` is never consulted because vendor/product matches win.
The fix uses the lookup order (Vendor_Product before name, /system before /data per name): `/data/system/devices/idc/Vendor_0001_Product_0001.idc` (= system `ft5x06.idc` + `keyboard.layout = crusty_tsw`) wins over `/system/usr/idc/ft5x06.idc`. `crusty_tsw.kl` in /data is the system Vendor_0001 layout plus `config/input/buttons.kl`. The extra idc lines dont affect the other three devices (`touch.*` is only read by touch mappers).

Lollipop's libinput has **no `WAKE` flag** (only VIRTUAL/FUNCTION/GESTURE; an unknown flag invalidates the whole file, very nice of it). Only BACK, POWER, MENU, SLEEP, WAKEUP and PAIRING wake the screen (`KeyEvent.isWakeKey`). The ft5x06 driver has no suspend hook, so the controller keeps scanning while the screen is off. (Thats the wrong earlier note, see "Screen off / power" for what really happens.)

Button LEDs: Amlogic `kpled` driver, `/sys/class/keypad_led/brightness` is chowned to `system` by init.amlogic.rc (so a platform-signed app can drive it). There is also a root-only `onoff` attribute (`led1..led5`, `0/1`). crestrons `libuiHAL.so` reads `/dev/input/event*` itself and drives the LEDs. With the crestron UI gone nothing turns them back on.

Found with the crusty logs: ~90 s after boot crestrons platform daemon (logs as `TSXPlatform` / `UIHalUtility`: "Unable to Set PM", "No LED mapping needed") writes `/sys/class/backlight/aml-bl/brightness` straight to 255 (Android's setting was 165) and turns the button LEDs off **around** the kpled driver: sysfs keeps saying `brightness=128`, `real_status=ON(1)`. What a liar.
Writing kpled `brightness` again (0 then level) brings them back for good. The companion (0.3) detects backlight changes that werent made by Android or itself, restores Android's brightness and re-applies the LEDs. It also re-applies them at boot+120/180/300 s. `/data/crusty/config/keep_external_backlight` opts out of the backlight part.

## Logs

Crestron logs logcat/kernel into RAM (`/dev/crestron/ramLogs`) and only copies them to `/logs` (SD p8) in `gracefulReboot.sh`. A power pull loses the session, and the rotated `*.plogprevious.<date>` files keep the same name because the panel's clock restarts at the same 2024 date every boot. `console-ramoops` only has early kernel boot. So for debugging I'd need my own log saver.

## Later: writing the internal eMMC via Crestron's own updater (not investigated yet)

The idea (mine): the reset button on the back (pressed ~10x right after boot) may make the panel reflash the internal eMMC from the SD card.

Quick findings, only partly confirmed:
- `/system/bin/crestronLocalUpgrade.sh` (426 lines) **does write the eMMC**: from an extracted `image_*.zip` in `/mnt/sdcard/ROMDISK/romdisk/user/system/` (+ `image/`, i.e. SD **p5**) it `dd`s `u-boot.bin` -> mmcblk0 (SD) + `mmcblk1boot0/1` + `/dev/block/bootloader`, `system.img` -> `/dev/block/system`, `boot.img` -> `/dev/block/boot` (md5-verified), `logo.img` -> `/dev/block/logo`, and `system-golden.img` -> SD p2.
- `crestInit.sh` runs it on firmware updates (`fwUpgrade=1`) and in golden mode (`crestronLocalUpgrade.sh GOLDEN`, then `fw_setenv fwUpgrade 0`, `update_golden_version 1`, reboot).
- Golden mode = booting SD p1/p2. u-boot env has `golden`, `golden_boot_retry`, `boot_retry`, `key=saradc open 0` (an ADC key read in u-boot). The 10x-press mechanism itself wasnt traced. It may set `golden`/boot-retry, which would fit "boot golden -> reflash eMMC from SD".
- Not checked yet: whether `image_*.zip` is hash/signature-checked (`NOHASHCHECK=0` suggests a hash, but possibly not a signature), and whats in p5's `ROMDISK/romdisk/user/system/` today.

If it holds, a modified `image_*.zip` (our boot.img/system.img/logo.img) on p5 + triggering golden mode could put crusty on the eMMC, which would unlock removing native daemons, custom u-boot logo, mainline kernel, etc. **RISKY: it also rewrites u-boot on the eMMC. Needs a full plan + backups (dump of the eMMC first) before trying.**

## crusty companion app (app/companion)

Our own small app, built from source by `tools/build-apps.sh` (Android 5.1 SDK `android.jar` + Eclipse compiler ECJ + d8; javac 25 output crashes d8 from build-tools 34, so ECJ it is). Platform-signed with `sharedUserId=android.uid.system`, so it can read logs, run dumpsys, hold wakelocks and write `/sys/class/keypad_led/brightness`.

- **No suspend**: holds a PARTIAL_WAKE_LOCK (cheap insurance; the real power problem was early-suspend, see "Screen off / power"). `/data/crusty/config/allow_suspend` disables it.
- **ButtonService** (accessibility, key filter, enabled via settings.ini): power (BUTTON_1) short = blank/unblank, long = crusty app; HOME -> start home; while blanked any key/touch wakes.
- Pins `screen_off_timeout` to max (`config/allow_screen_timeout` to opt out).
- **Persistent logs** in `/data/crusty/logs/boot-NNN/` (last 10 boots, `logs/latest` names the current one): `logcat.txt` (+ rotations), `kernel.txt` (dmesg every 30 s), `events.txt` (service start, screen on/off, LED attribute changes, button actions), `snapshots/*.txt` (dumpsys window policy/windows/activity/package preferred/input/power/statusbar, LED attrs, getprop) at boot+20 s, every 5 min and on demand. Read offline: `debugfs -R "rdump /crusty/logs work/card" work/card/p6.img` (from `tools/read-data.sh` or a dd of p6).
- **Button LEDs**: re-sets `brightness` (default 255, `config/led_level`) on screen-on and when it drops to 0 while the screen is on. `config/led_no_keep_on` disables it.
- UI: status, "Save snapshot now", "Test: start HOME intent directly", "Test: list HOME apps".
- New non-system packages start in the *stopped* state, so BOOT_COMPLETED only arrives after the app was opened once.

### Companion 0.4: settings app

Everything is configured in the crusty app (Android preference screens, stored in the app's default SharedPreferences, so its readable offline at `/data/data/dev.crusty.companion/shared_prefs/`):

- **Side buttons**: all five send BUTTON_1..5 (`config/input/buttons.kl`) and only mean what crusty says. Power is fixed (short = blank, long = crusty). Home/Lamp/Up/Down get a short and a long action (home, back, recents, notifications, quick settings, volume +/-, mute, brightness +/-, screen off, LEDs on/off, launch app, open crusty). **App profiles** override them per foreground app; the foreground app comes from accessibility `TYPE_WINDOW_STATE_CHANGED`.
- **LEDs**: one level for all five (the per-LED `onoff` attribute is root-only; only `brightness` is chowned to system). Awake: on / light-on-touch (N s) / off. Blanked: off / dim / on. Touches are seen by a 1x1 `FLAG_WATCH_OUTSIDE_TOUCH` overlay (ACTION_OUTSIDE for every touch, nothing eaten), which also drives **screen off after inactivity**.
- **Android tweaks**: hide status bar = `Settings.Global.policy_control` `immersive.status=*:immersive.preconfirms=*`. Nav bar on/off = `Settings.Global.crusty_navbar`, read by our SystemUI patch (`CrustyHome.showNavBar`). Toggling broadcasts `dev.crusty.RESTART_SYSTEMUI` (sender needs STATUS_BAR), SystemUI exits and, being persistent, is restarted. Also rotation, `wm density`, animation scales (re-applied when crestrons platform service disables them at boot) and show touches.
- **Kiosk** (no device owner needed): `StatusBarManager.disable(EXPAND|HOME|RECENT|...)`, bars hidden (optional), the accessibility service brings the kiosk app back whenever something else comes to the front, and button actions that would leave it are ignored. Leave: hold Power -> crusty (PIN) -> Leave kiosk. Plus **autostart app at boot**.
- **PIN** (salted SHA-256) for the crusty app. It locks again once no crusty screen is visible.
- **Crestron apps**: enable/disable each `com.crestron.*`, `air.air.*`, `us.zoom.*` package (`setApplicationEnabledSetting`).
  - Note : `config/disable-packages.txt` is re-applied by `tools/mod-data.py` on every build.
- **Logging** toggles (logcat, kernel log, periodic snapshots), reboot / power off.

## Golden mode = crusty maintenance mode (SD card only, root)

- **Trigger**: u-boot boots crestrons golden fallback (SD p1 `boot.img` + SD p2 `/system`) when `boot_retry` reaches a threshold. crestrons updater uses `fw_setenv boot_retry 10` ("Boot into Golden Image"); u-boot increments it every boot and `logBootComplete.sh` resets it after a successful *normal* boot. The u-boot env is **on the SD card** (`fw_env.config`: `/dev/block/mmcblk0 0x100000 0x10000` = p3): CRC32 LE + `name=value\0...`. `tools/ubootenv.py` prints/edits it (`golden` / `normal` presets). The rear reset button (10x after boot) probably drives the same mechanism (not confirmed).
- **crestrons golden path is destructive**: with `DataRecoveryDone!=1` crestInit sets `reformatDataPartition=1` + reboots, then `cleanUpCache.sh FORMAT` mke2fs's SD p5/p6/p7; with `fwUpgrade=1` `crestronLocalUpgrade.sh` dd's u-boot/boot/system/logo onto the eMMC. No bueno!
- **crusty's golden**: `tools/mod-golden.py` replaces p2's `crestInit.sh` with `app/golden/crestInit.sh` and stubs `cleanUpCache.sh`, `crestronLocalUpgrade.sh`, `crestronUpgrade.sh` (originals kept as `*.crestron`, SELinux label `system_file`). p2 is only used in golden mode, so normal boots are unaffected. The script runs as root: pets the watchdog, resets `boot_retry`, then stays running and keeps `/data/crusty/golden-status` up to date. The companion shows a "Mmmm yes, this is golden mode" banner with touch buttons. It cant do root work itself, so it writes a request to `/data/crusty/golden-request` (dir chowned to system by the script). "Back up eMMC to USB stick" copies the whole eMMC to a FAT32 stick (`mmcblk1` in 1 GiB parts + boot0/boot1 + MD5SUMS + info.txt; eMMC only read). It reuses vold's mount if Android already mounted the stick (never double-mounts a FAT fs rw) and checks free space first.
- Block devices are `root:root 0600`, so the normal-mode companion (system uid) cant touch the eMMC; golden mode is the root path.
- First golden run: requests arrived but nothing happened. The panel's busybox `stat` has `-f`/`-t` but **no `-c`** (`invalid option -- c`). The empty result made `$(( * ))` fail, and mksh aborts the function on an arithmetic error (silently, apart from logcat via logwrapper, thanks mksh). Fixed: `stat -f -t` (terse: `$6` = block size, `$9` = available blocks), validated before any arithmetic. Every request is acknowledged, the action runs in a subshell, and errors show on the banner (status + last lines of golden.log, "script not responding" after 8 s). `tests/golden/run.sh` runs the script on the PC against a fake eMMC/USB stick with a busybox mock that behaves like the panel's.
- Second golden run: "backup DONE (0 parts)". **mksh arithmetic is 32-bit**, and the eMMC (3817472 KiB ~= 3.9e9 bytes) overflowed the byte count. Now all sizes are KiB/MiB (`/proc/partitions`, stat -f -t blocks scaled down before multiplying). eMMC layout confirmed from `/proc/partitions` in golden mode: mmcblk1 3817472 KiB; p1 4 MiB, p2 64 MiB, p3 512 MiB, p4 48 MiB, p5-p7 32 MiB, p8 1 GiB, p9 1.85 GiB; boot0/boot1 4 MiB each. `tests/golden/run.sh` uses mksh (32-bit, like the panel) if installed.
- Golden banner also has **"Save logs & shut down"**: the script copies golden.log, /data/crusty/logs, dmesg and logcat to the USB stick (if present), syncs and powers off (`reboot -p`).
- Third run: part 3 failed with `dd: /dev/block/mmcblk1: Invalid argument`. Android's toolbox dd has a **32-bit offset**, so `skip=` at 2 GiB cant seek. Now one sequential `dd | busybox split -b 1G` (no seeking). Verification is end to end: a second sequential reader md5s the eMMC during the copy (no `tee` in this busybox), then the page cache is dropped and `cat parts | md5sum` reads the backup back from the stick. Both must match (`MD5SUMS` line `mmcblk1.img` = cat of the parts). The test harness checks this, including a simulated corrupted stick (`CORRUPT=1`).
- Golden banner progress comes from the kernel's block statistics (`/sys/block/sdX/stat`, world-readable): sectors written to the stick while copying, sectors read from it while verifying. No access to the stick's files needed (the system uid apparently cant list them in golden mode).
- First complete backup: 4 parts = 3,909,091,328 bytes = 3817472 KiB (dd: 431 s, ~9 MB/s on a slow stick).
- "Save logs & shut down" never powered off: **`/system/bin/reboot` on this firmware is a Crestron bash wrapper** that ignores `-p`, daemonizes `gracefulReboot.sh` and then `sleep`s forever (ewww, gross!). The golden script now uses `setprop sys.powerctl shutdown` (init -> android_reboot; the kernel has `rn5t618_power_off`), switches backlight/LEDs off first, and falls back to sysrq `o` after 20 s.
- **Verified full eMMC backup** (14 GB stick): copy 8.7 min, verify 1.8 min; md5 of the whole eMMC `c378a34c66a8074bccbc748543c40f2f` == read back from the stick on the panel == PC copy (`work/emmc-backup/`, cat the parts). Shutdown via `sys.powerctl` works. BOOM!

## Internal eMMC contents (from the backup, `tools/extract-emmc.py`)

`tools/extract-emmc.py [work/emmc-backup] [work/emmc]` verifies the backup's md5, reads the Amlogic partition table (`MPT` at 0x2400000: header + 40-byte entries `name[16] u64 size u64 offset u32 mask`) and carves/unpacks everything into `work/emmc/`.

| partition  | size     | content                                                                                                                                     |
|------------|----------|---------------------------------------------------------------------------------------------------------------------------------------------|
| bootloader | 4 MiB    | identical to the SD card's bootloader (after the MBR)                                                                                       |
| reserved   | 64 MiB   | partition table (MPT) + Amlogic key/env storage                                                                                             |
| cache      | 512 MiB  | ext4, `recovery/last_log*`                                                                                                                  |
| logo       | 48 MiB   | `AML_RES!` v2 container x2 (0x0 and 0x1000000): `bootup` (360x360, the u-boot boot logo), `bootup_5inch`, `upgrade_*` screens               |
| recovery   | 32 MiB   | Android boot image, kernel 3.10.33 built 2015-10-22, Amlogic stock recovery ("AOSP on yushan_one")                                          |
| misc       | 32 MiB   | empty                                                                                                                                       |
| boot       | 32 MiB   | boot.img (2024-06-04): same kernel as SD p1; ramdisk differs only in fstab (`/dev/block/system` instead of mmcblk0p2) and a build timestamp |
| system     | 1 GiB    | **byte-identical to the SD card's golden p2**                                                                                               |
| data       | 1.85 GiB | old factory-state `/data` from 2015 (unused: the live /data is SD p6)                                                                       |

`AML_RES!` item header (0x40 bytes): `u32 magic 0x27051956, crc, size, start, 0, next, 0; u8 idx, count; u16; char name[32]` (start/next relative to the container).

## Later (parked): Linux with GPU / video acceleration on the existing 3.10 kernel

Not pursued for now, the focus is a polished Android 5.1 first. Notes for when I get back to it:

- Kernel side is all there: Mali-450 `mali-utgard` (`/boot/mali.ko` in the boot ramdisk, `API_VERSION=800`, built 2015) and the Amlogic video stack (`/dev/amstream*`, `/dev/amvideo`, vdec drivers; on Android used via libamplayer/libamcodec/OMX).
- Mainline Linux supports Meson8m2, but display + video decode/encode are the biggest missing pieces, so a touchpanel would stay on the vendor 3.10 kernel.
- GPU userspace must match the kernel driver's API version: either an r6p1-era Linux libMali (fbdev/X11, as Hardkernel shipped for ODROID Mali-450 boards; API 800 <-> r6p1 assumed, unverified), or **libhybris** with the panel's own Android `libGLES_mali.so` (guaranteed match).
- Video: Amlogic `aml-libs`/`libamcodec` built for armhf (ODROID precedent: Kodi HW decoding); decoded video goes to the hardware video plane under the framebuffer, independent of the GPU.
- Realistic target: GLES2 on fbdev for one fullscreen app (Qt eglfs / Kodi / kiosk UI), not an accelerated composited desktop.
- Test order: (1) modified boot.img boots? (SD p1, golden) (2) Debian armhf on our kernel from SD p5 / USB: fbdev, touch, network (3) GPU via libhybris and/or r6p1 blob (4) libamcodec decode test.

## Web: certificates, clock, browser

- **Root CAs are fine**: `/system/etc/security/cacerts` is a Crestron symlink -> `/data/system/security/android_old_hash` -> `.../root/*` -> `/system/etc/security/cacerts_bak` (163 certs, updated by Crestron ~2023: ISRG X1/X2, GTS, Amazon, USERTrust... present). The indirection is for crestrons "import root certificate" feature (`import_root_certs.dat`).
- **The SSL errors come from the clock**: `Settings.Global auto_time=0` and crestrons ntpsec fails at boot ("unable to bind ... EXITING"), so the clock stays at crestrons build date (2024-10-22; 1970 in golden). Companion 0.7 (`NtpSync`) turns `auto_time` back on, sets `ntp_server` and does SNTP itself (SET_TIME as system uid): at start (retry every minute), then every 6 h. Settings: Date & time.
- **Browser**: the bundled `org.chromium.chrome` is Chromium **47** (2015); the system WebView is 95 (Crestron-built and signed, about the last one for Android 5, cant be updated without their key). **Firefox 143.0.4** (org.mozilla.firefox, minSdk 21, armeabi-v7a) is the last Firefox for Android 5-7 and brings its own engine; installs via AppInstaller from USB.

## crusty eMMC update (first write to the internal eMMC)

`tools/build-emmc.py` builds, from the verified backup (`work/emmc/raw`):
- `out/crusty-emmc-update/{system,logo}.img + MANIFEST` and `out/crusty-emmc-restore/` (the originals).
- **system** (ext4, debugfs like the SD card): grown 622 MiB -> 1 GiB (whole partition; was 24 MiB free, now ~368 MiB; `e2fsck -fy` after resize2fs fixes the stale resize-inode size); Chromium 47 -> Chromium 95.0.4638.0 (snapshot r920003 = M95 branch point, the last Lollipop release; `/system/app/ChromePublic`, libs in `lib/arm`, `crazy.libchrome.so` loaded from the APK); `android.policy.jar` Home fix (`if-eqz` on the null `mKeyguardDelegate` in `launchHomeFromHotKey`); custom `bootanimation.zip` (STORED); `/system/bin/crusty-boot.sh` started as root from line 2 of `crestInit.sh` (chowns kpled `onoff`/`brightness` to system); `/system/homepage` replaced by a crusty page (keeps `errors/`). New files: root, 0644/0755, `u:object_r:system_file:s0`.
- **logo**: `bootup` converted to a classic 40-byte-header BMP in both AML_RES containers; container CRC = `~crc32(data[4:img_size])` (item CRC fields are 0).
- Golden script **install/restore**: pass 1 verifies image md5 on the stick, partition size and that the partition is in a known state (original or an earlier crusty build; restore = any); pass 2 writes, drops caches, reads back and compares. Tested on the PC: `tests/golden/install.sh`.
- **Incremental** (so updates dont rewrite 1 GiB every time): `build-emmc.py` writes `<img>.chunks` (`# chunk_kib 4096` + one md5 per 4 MiB chunk). With a chunk list, pass 1 compares every chunk of the partition and checks each *differing* chunk on the stick against the list (a damaged stick is refused before anything is written); pass 2 writes only those chunks (64 KiB dd blocks, offsets < 1 GiB for 32-bit dd), then the usual full read-back verify. The banner shows "comparing/writing chunk n of m".
- **Stick side**: `tools/sync-stick.py <mountpoint> out/crusty-emmc-update out/crusty-emmc-restore` rewrites only differing 4 MiB chunks of files already on the stick, then evicts the page cache and reads everything back to verify.

## Root: phh's Superuser (system su + manager app)

No maintained prebuilt open-source su exists for Android 5 (what a shocker), so `tools/build-su.sh` builds [phh's Superuser](https://github.com/phhusson/Superuser) (GPL-3, pinned commit 9ae9705):
- **su**: NDK r25c clang, static, armeabi-v7a, API 21. Fixes for a modern toolchain: GCC nested functions in `binds.c`/`daemon.c` rewritten as static functions by `tools/su/unnest.py` (the callbacks only use function-static variables); `<cutils/multiuser.h>` shim; all of libselinux except `android.c` and pcre-dependent `label_file.c` (stubbed, su never uses it).
- **manager app** `me.phh.superuser` 1.0.3.3 without Gradle (AGP 1.2.3 is unusable today): aapt2 with app + Widgets resources merged, ECJ, d8 incl. `android-support-v4.jar`; signed with a seperate crusty app key (`work/.cache/crusty-apps.p12`), not the platform key.
- Installed by `tools/build-emmc.py`: `/system/xbin/su`, `/system/app/Superuser`; `crusty-boot.sh` starts `su --daemon` as root at boot (`/data/crusty/config/root_disabled` turns it off).

## Crestron audit: what's running and what is needed

How things start: `init.crestron.rc` starts only `cleanUpCache`, `ftpd`, `crestInit` and `lldpd`. Everything else comes from `crestInit.sh`, `logBootComplete.sh` (on `sys.boot_completed`) or other crestron daemons. About 190 MB RSS of crestron native processes, ~30% of all logcat lines. They love yapping.

| what                                                                                           | started by                                   | does                                                                            | verdict                                                                             |
|------------------------------------------------------------------------------------------------|----------------------------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| autoUpdater, FITCProxy, HydrogenManager                                                        | logBootComplete.sh:165, crestInit.sh:939-943 | firmware/APK auto-update, cloud (XiO/Fusion)                                    | remove first (could overwrite crusty)                                               |
| ftpd, telnetd, sshd (root, empty password allowed), ctpd, cipclientd, CrestronDiscovery, snmpd | init.rc / crestInit / logBootComplete        | network services                                                                | remove; use adb instead                                                             |
| speechtotextservice, com.crestron.service, bluetoothleservice, pjsip                           | APKs                                         | voice, keyboard joins, ...                                                      | `pm disable`                                                                        |
| platformd (+ csiod, CPHProcessor)                                                              | logBootComplete.sh:117/168                   | backlight, LEDs, ALS, standby, app watchdog, periodic reboot, LLDP PoE requests | remove with stubs: crusty already does LEDs/backlight; ALS would need a replacement |
| a_console, crestErrorLogServer, redis (CresStore)                                              | crestInit.sh:815-817                         | console, error log, settings store, an ntp loop                                 | remove after platformd, use Android's auto time                                     |
| txrxservice, com.crestron.platform                                                             | APKs                                         | AirMedia/streaming; JNI bridge to platformd                                     | try removing one at a time (see below)                                              |
| lldpd                                                                                          | init.rc                                      | LLDP                                                                            | keep if the panel is on PoE+ (power negotiation)                                    |
| AndroidEthInit, dhcpcd                                                                         | crestInit.sh:781                             | eth0 MAC, hostname, DHCP                                                        | keep or reimplement                                                                 |
| pet                                                                                            | logBootComplete.sh:120                       | feeds /dev/watchdog                                                             | probably not needed (below)                                                         |
| lighttpd                                                                                       | logBootComplete.sh:173                       | web server                                                                      | keep, own config                                                                    |

The "boot hangs without com.crestron.platform/txrxservice" theory doesnt hold: the `IUiModeManager` NPE ("BOOT FAILURE making Window Manager Service ready") happens on every boot, the good ones too. Crestron removed `UiModeManagerService` from `SystemServer`, so `PhoneWindowManager.updateUiMode()` gets null inside `systemReady()`. Its caught, but the rest of `systemReady()` (orientation listener, `mSystemReady=true`) is skipped every boot. A null check in android.policy.jar would fix that. The framework only references Crestron in `Watchdog` (sends a `SET_DIGITAL` intent before rebooting anyway) and `LocationManager` (lat/long props). What really hung that boot is unknown (its logs are gone), so re-test with logging.

Things crestInit/logBootComplete do that have to stay (or be redone): `/dev/shm` symlink, AndroidEthInit, `/dev/shm/CrestInitComplete`, `fw_setenv boot_retry 0` (else u-boot ends up in golden mode), and `/dev/shm/LogBootCompleteComplete` - crestInit.sh:1011-1018 **reboots the panel 300 s after it finishes** if that file is missing. Things I dont want: `stop adbd` (:777), `chmod -R 777 /data/*` every boot (:747) (yes, really), and Chromium's data dir on tmpfs (:721-731), so the browser profile is wiped at every boot.

Watchdog: `aml_wdt`, 8 s max timeout, and the kernel feeds it itself every 2 s (`reset_watchdog_method=1`). Userspace (`pet`) only starts ~190 s after boot and the panel never resets in between, so removing `pet` looks safe. DONT use AOSP's `watchdogd 10 20` (30 s > 8 s max).

Web server: lighttpd 1.4.52 (static), started late (boot complete + 20 s, an EEPROM `webserverState` flag, then waits for CPHProcessor's `/dev/shm/CPHReady` up to 300 s). Config is copied from `/system/crestron/webserver/sdcard/web/conf/` to `/data/web/conf/` every boot; the `Mobility_auth*.conf` it includes sends `/` to `/sdcard/ROMDISK/ftp/html/index_banner.html`, which is why our `/system/homepage` page doesnt show on `/`.

Plan, one step per build: web server -> disable the extra APKs -> updater/cloud -> network services -> platformd (+csio, CPHProcessor) -> re-test txrx/platform APKs -> a_console/errlog/redis -> replace crestInit.sh + logBootComplete.sh with one short crusty script.

First strip-down (build-emmc.py `CRESTINIT_OFF`/`LOGBOOT_OFF`, crusty-boot.sh, mod-data.py): cloud (FITCProxy, HydrogenManager, recoverHydMgr), autoUpdater, installAPKs/restoreAppFromBackup/ makeCore3CacheDir, CrestronDiscovery, snmpd switched off; ftpd/telnetd/sshd stopped after boot; `stop adbd` removed; speechtotextservice, com.crestron.service, bluetoothleservice, pjsip disabled; lighttpd runs crusty's own config; `persist.sys.app.browser_cache=true` keeps Chromium's profile (its data dir was owned by crestrons old browser uid 10002, now Chromium's). Still there: platformd/csio/CPHProcessor, a_console, ctpd (crusty uses its console), cipclientd, errlog, redis, lldpd, pet, txrx + platform APKs.

PoE: the panel runs only on PoE, so lldpd stays. lldpd alone doesnt ask the switch for PoE+ power though: platformd does that (polls `lldpcli`, sends "dot3 power pd ... class-4"). Before platformd goes, crusty has to send that request itself (`lldpcli configure dot3 power pd supported enabled powerpairs signal class class-4` or similar, to be checked against what platformd sends).

Remote shell: crestrons OpenSSH is patched to use crestrons user database (`crestron_getpwnam`, AD service) and forces logins into `sshShell.sh` (the Crestron console), so its stopped. crusty brings Dropbear (tools/build-dropbear.sh): static, key-only, root, port 22, started by crusty-boot.sh when `/data/crusty/ssh/authorized_keys` exists (put there by mod-data.py from config/ssh/authorized_keys). Dropbear wants every folder above authorized_keys to be root-owned and not group-writable; /data is 0771 system, so the keys are copied to /dev/.crusty_ssh at start. Host key: /data/crusty/ssh/host_ed25519 (made on first start).

kpled LED numbering (`onoff`: `led<n> <0|1>`), checked on the panel, top to bottom: led5 = Power, led4 = Home, led3 = Lamp (center), led2 = Up, led1 = Down.
- Superuser: Allow button had filterTouchesWhenObscured; a Crestron overlay window always covers the screen, so taps on Allow were dropped. Removed in tools/build-su.sh (the 3 s countdown stays).

Boot time: a normal -> normal reboot reaches ActivityManager ready in ~35 s. ~135 s boots are recompiles: golden mode and the normal system share the SD card's /data (dalvik-cache), so each switch (and every eMMC update) regenerates boot.art and recompiles apps, and an unfinished boot leaves ART's `/data/dalvik-cache/arm/.booting` marker ("Incomplete boot detected. Pruning dalvik cache"). "Unable to mark boot complete ... No such file" from installd is harmless noise.

Golden mode from the app: crusty -> System -> "Reboot to golden mode" creates /data/crusty/run/golden-request; crusty-boot.sh (root) sets boot_retry=10 plus the same safety values as `tools/ubootenv.py golden`, after crestrons logBootComplete.sh is done (it resets boot_retry to 0), and answers in golden-status; the app then reboots.

> Note : flash p3 from the card's own env (read it first) - an old copy taken in golden mode has golden=1 / a different bootcmd and resets other values.

- Dropbear logins died with Bionic FORTIFY "fgets: buffer size 0 <= 0": the OpenBSD getusershell() compat code always ends with fgets(size 0) (glibc returns NULL, Bionic aborts). Patched in build-dropbear.sh; /system/etc/shells now lists sh/bash (crestrons only had telnetSSHProxy, no newline).
- Dropbear vs. today's Bionic (NDK libc.a): getpwnam() gives root the shell /bin/sh (no /bin on Lollipop) -> patched to fall back to /system/bin/sh; ptys: configure cant detect /dev/ptmx when cross-compiling -> USE_DEV_PTMX forced.

Second strip-down, tested live over SSH first (each stopped with `stop <service>`, panel soaked for minutes: no reboot, network/backlight/LEDs/touch fine):
- platformd, csiod, autoUpdater (platformd starts those two), cipclientd, CPHProcessor
- a_console, ctpd (+ AuditLogService, IpBlockerService), cresterrlog, redis, crestrons ntpd
- pet: panel stays up without it (aml_wdt max timeout 8 s, the kernel feeds it). Left in place.

Now off in the build (CRESTINIT_OFF / LOGBOOT_OFF), except pet and lldpd.

Persistent Crestron apps (txrxservice, speechtotextservice, com.crestron.service): Android 5 restarts PERSISTENT apps even when disabled (enabled=2), and `pm hide` makes it worse (start/die loop several times a second). They, and com.crestron.platform, are removed from the image (REMOVE_APPS). txrxservice kept a TYPE_SYSTEM_OVERLAY window (1024x600 at 0,0) on top of everything, which is what made buttons with filterTouchesWhenObscured dead (Superuser's Allow, Android's install/permission buttons).

platformd's Crestron settings before it went (CTP console): KEYBKL 100 %, KEYBACKLTATSTBY on, KEYWAKE on, auto-brightness off, STBYTO 0, screensaver off. CAREFUL with that console: `STANDBY` without arguments puts the panel into standby (`STANDBY OFF` leaves it).

PoE/LLDP: libuiHAL sends, via lldpcli: `configure ports eth0 dot3 power pd supported enabled powerpairs signal class class-4 type 2 source pse priority high request <N> allocated <N>`. The values are computed at runtime; not replicated yet (no LLDP neighbour on the test network - to be captured on a PoE+ switch by starting redis, cresterrlog and platformd by hand).

Third round, verified on the panel after a golden install: boots fine without platformd & co and without com.crestron.platform / txrxservice (so much for "required"). Left from Crestron at runtime: lldpd, pet, one ntpsec (started by the DHCP hook), plus crestInit.sh/logBootComplete.sh themselves. No overlay window, no backlight/LED overrides anymore, ~1 GB of 1.7 GB RAM free. crusty 0.12 dropped all the re-apply code that fought platformd.

PoE on a UniFi USW Pro Max 48 PoE (LLDP + PoE++ enabled on the port): the switch sends no Dot3 power TLV, platformd never sent a request (watched every lldpcli call for 4 min), and a manual request for 25.5 W got no answer. Power is by hardware classification only; nothing to replace.

Golden mode gets its own dalvik-cache: on SD p2, /system/bin/app_process is a small wrapper (app/golden/app_process) that binds /data/dalvik-cache-golden over /data/dalvik-cache before exec'ing app_process32. Before that the two Android builds kept invalidating each other's cache.
SELinux is disabled on this firmware (`getenforce` -> Disabled), so labels dont matter.
