# Crusty
Hobbyist friendly firmware Mod for EOL Crestron Touch Panels.

## Why
I have a bunch of TSW-760 Touch Panels, I dont want to use them with Crestron stuff and even if I did I dont have access to the software to program Crestron touch panels.

When I took one appart out of curiosity I found that theres a small 4GB SD Card in them which seems to have the entire OS on it (android based as it seems)

## Goal
There is no real defined single goal but rather some things id like to achieve:

- Modify the Firmware to break out of the Crestrons Propriatary environement to access the Android below it.
- See how realistic it would be to port either a newer build of android or debian for arm to it.
- Custom Boot Splash
- Maybe TWRP ?

## What it does so far
Turns the panel from a very expensive crestron remote into a slightly crusty but actually usable Android 5.1 tablet that lives in your wall.

- AOSP Launcher and Settings, a working status bar, notification shade and nav bar (crestron shipped the empty Android TV one, what a shocker)
- crestrons UI apps are disabled and most of their daemons are gone, the side buttons do Back/Home/Recents/etc. (configurable)
- crusty, a companion app: button actions and per-app profiles, button LEDs (each one on its own), screen off after idle, kiosk mode with a PIN, Android tweaks, logs that survive a reboot
- Chromium 95 instead of the Chromium 47 it came with
- custom boot logo, boot animation and wallpaper (in [branding/](branding/))
- root (phh's Superuser, built from source) and ssh (Dropbear, key login only)
- golden mode (the reset-button recovery) turned into a maintenance mode that backs up the internal eMMC to a USB stick and installs/restores updates to it, only writing what changed

All the findings, partition layouts and the weird stuff I ran into are in [docs/ANALYSIS.md](docs/ANALYSIS.md), its long yapping dump (no organization sry)

Before you start ripping panels out of walls please read [The scary bits](#the-scary-bits)!

## Getting started
You need a TSW-760 (Technically TSW-560 and TSW-1060 should also work but untested), a microSD card reader, a FAT32 USB stick with 8 GB or more and a Linux PC.

```bash
./setup.sh
```

It walks you through everything: taking out the card, backing up the card and the eMMC, building and installing.
It remembers where you got to so you can stop, go touch grass and come back.

If it complains about missing programs, on Debian/Ubuntu install this stuff:

```bash
sudo apt install python3 default-jdk curl unzip p7zip-full openssl e2fsprogs fdisk cpio gzip lz4 udisks2 whiptail
```

Changed something (a config, a patch, the app)? This rebuilds and writes only what changed:

```bash
./setup.sh update
```

It asks how the update gets to the panel: via the USB stick (golden mode installs it itself, More -> "Update recovery from USB stick", the card stays in the panel) or via the SD card (card into the PC, /data is read, only changed chunks get written). The USB way needs a golden mode that already has that button, so the very first time use the card.

> Note : the settings that get baked in live in [config/](config/). Your ssh public key goes in `config/ssh/authorized_keys` (git-ignored), without it there is no ssh at all.

## Doing it by hand
If you dont trust a script with your SD card (fair), every step `setup.sh` runs is written out with the real commands in [docs/BY-HAND.md](docs/BY-HAND.md). That file also has the PC side tests for the golden mode script.

## More panels
Got a pile of these? After `./setup.sh` finished on the first one every other panel is just this, no card dump and no rebuilding everything:

```bash
./install.sh
```

Plug in the stock microSD card of the next panel and follow it. It checks that the card is the same model and firmware as panel 1 (otherwise it says no, that one needs its own `./setup.sh`), patches only that panels own p2, p3 and p6 and writes the changed chunks, about 140 MiB. Then it preps the USB stick, the same stick works for all panels (aslong as its got enough storage, expect around 4.5ish GB per panel if you do eMMC backups)

On the panel it is golden mode again, optionally "Back up eMMC to USB stick" (the folder is named after the panels ethernet MAC which is the only thing FW wise that exists as a label on the back of mine), then "Update eMMC from USB stick".

- everything panel specific lands in `work/panels/<MAC>/`, including the stock p3 and p6 of that card.
- `./install.sh --dry-run` builds but writes nothing.
- what is shared and what is per panel is in [docs/ANALYSIS.md](docs/ANALYSIS.md), "More panels".

## The scary bits
**YOU NEED YOUR OWN DUMP.** Nothing from the panel is in this repo and it will stay that way, crestrons firmware is theirs (and they get real angry if you distribute it, ask me how I know). Your own dumps go to `img/` and `work/` (both git ignored), everything else gets downloaded from public sources and checksum checked. So no, there is no ready made image to download, dont ask.

**BACK UP FIRST, BOTH SD AND EMMC.** The panel has two storage devices, the SD card and an internal eMMC. The card is easy, you can always re-image it from your dump so keep `img/sdcard.img` somewhere safe. The eMMC is internal, you cant just pull it out and reimage it, so if that one is toast you need a working way back and thats what the eMMC backup in golden mode is for. `setup.sh` makes you do each backup before the thing in question gets written. DO NOT SKIP IT, and keep `out/crusty-emmc-restore/` on the stick, "Restore original eMMC from USB" in golden mode is your way back.

Getting the original card back is one command:

```bash
tools/flash.sh img/sdcard.img /dev/sdX
```

**THIS WRITES TO BLOCK DEVICES.** `tools/flash.sh` checks that the target is removable, not mounted and the right size and asks before it writes, it will still happily eat whatever card you point it at. `/dev/sdX` is YOUR job to get right.

**AT YOUR OWN RISK.** This is a hobby project for panels that are EOL anyway. The eMMC install verifies the images on the stick, checks the partition is in a state it knows and reads everything back after writing, and it only touches `system` and `logo` (never u-boot). It worked on my panel, that is all the warranty you get. If yours turns into a brick thats sad but (not my problem).

**ITS NOT SECURE AND ISNT TRYING TO BE.** The firmware is signed with the public AOSP test keys (crestron did that, not me), there is a root shell on port 22 (key only at least) and a su that any app can ask for. Fine on your home notwork, no bueno anywhere you dont trust. KEEP THIS IN MIND!

## How it actually works
- The panel normally boots `/system` from the internal eMMC but takes `/data` from the SD card. So the first round never touches the eMMC: `tools/mod-data.py` puts our apps, the disabled package list, the key layout and the settings straight into the cards /data image.
  - Note : the platform key is the public AOSP test key, thats the only reason our Settings and SystemUI get accepted as system apps.
- The card also holds crestrons "golden" fallback system (the thing the reset button gets you into). `tools/mod-golden.py` swaps its init script for ours so golden mode becomes a root maintenance mode with touch buttons, normal boots dont notice.
  - Note : crestrons own golden mode reformats your data and reflashes the eMMC including u-boot. Ours doesnt, those scripts are stubbed.
- `tools/ubootenv.py golden` flips the u-boot env on the card so the next boot lands there. Later you get there from the app: crusty -> System -> "Reboot to golden mode".
- The golden screen has the common actions on top (back up, update (tick "Flash RAW (slow)" to rewrite everything instead of only the changed chunks, also for restore), save logs, reboot, shut down with a "Stay in golden mode" tick so the next boot is golden again) and a "More" list: brightness slider (golden mode is dim by default), restore, network info / start network, ssh server (keys are the ones from `/data/crusty/ssh`, import more from the stick), verbose boot (serial console, or the kernel log on screen from when Android starts: the kernel has no on-screen console), update recovery from the stick (so the card never has to leave the panel again: `setup.sh update` puts `crusty-recovery-update/` on the stick), system info, u-boot env, clear apps' data, reset crusty settings + PIN.
- In golden mode "Back up eMMC to USB stick" copies the whole eMMC to the stick and verifies it end to end with md5 (about 9 minutes copy, 2 minutes verify).
- On the PC `tools/build-emmc.py` builds a new `system` and `logo` from that backup: Chromium 95, su, Dropbear, the Home key fix, boot animation, boot logo, and most crestron daemons switched off.
- Back in golden mode the install compares the eMMC in 4 MiB chunks and writes only the ones that differ, then reads it all back.
  - Note : the first boot after an eMMC update takes about 135 s instead of 35 s because Android recompiles everything. Its not hung, leave it alone.
- From then on its `./setup.sh update` whenever you change something.

## Anythings else
- NEVER map a side button to POWER or SLEEP and dont let Android turn the screen off by itself. Its screen-off puts the touch controller in reset and the side buttons are part of that touch controller, so nothing can wake the panel anymore. crusty does its own "screen off" (backlight to 0 + a black overlay) for exactly that reason.
- the panel runs on PoE only. On the switch i've tested there was no LLDP power negotiation going on at all, its hardware classification only, so nothing had to be replaced there.
- SSL errors in the browser are usually the clock, crusty syncs it over NTP by itself now (Settings: Date & time).

## Known meh
Honest list of what is half baked or not there at all:

- [ ] Get rid of as much of crestrons stuff as possible. Three rounds done, whats still running from them: lldpd, pet, one ntpsec and crestInit.sh/logBootComplete.sh themselves. The plan is one short crusty script instead of those two (audit + progress in [docs/ANALYSIS.md](docs/ANALYSIS.md))
- [x] Web server: serve the crusty page on / (UNTESTED, so more like half an x)
- [ ] Ambient light sensor -> Android auto brightness. platformd was the one doing that and platformd is gone, so rn the sensor just sits there
- [ ] Serial console (UART_AO, 115200 8N1) to see u-boot output. Until then everything before the kernel is guesswork
- [ ] Later: Debian on the existing 3.10 kernel with GPU + video acceleration (parked, notes are in the analysis)
- [ ] Later: mainline kernel (meson8m2), headless

And the stuff thats not on the todo list but still meh:

- the nav bar is forced on behind the window managers back, so fullscreen/immersive apps cant hide it and apps get told a screen size that ignores it.
- every single boot throws an `IUiModeManager` NPE in the window manager because crestron removed a service, the rest of `systemReady()` gets skipped. Seems to work anyway, a null check in android.policy.jar would fix it, nobody did it yet.
- the system WebView is stuck at 95 forever, its signed with crestrons key and I dont have that.
- the 10x reset button press on the back probably triggers golden mode through the same u-boot counter, never actually traced it.
- crestrons second boot overlay (`crestronbootimage{2,3}.data`) is raw framebuffer data in a pixel format I didnt feel like decoding.
- only ever ran on the TSW-760 (7 inch). The boot image carries device trees for the 5 and 10 inch panels too, no idea if those work.
- the PoE+ request platformd could send is not replicated. Didnt matter on my switch, might matter on yours.

## Disclaimer on AI Usage
Blah blah blah, I am not learning java and python for this. This entire repo is basically me just telling an LLM to automate pokings/modifications I did to the device. Since I see these panels being thrown out alot I did however decide to publish this subpar repo of mine. Who doesnt want a PoE powered Android Kiosk for dirt cheap right?

