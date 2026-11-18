# Doing it by hand
What `setup.sh` runs, roughly in order. `/dev/sdX` is your card reader and `/media/$USER/STICK` is wherever your stick got mounted, you have to fill those in yourself.

Unpack your card dump into `work/`:

```bash
tools/extract.sh img/sdcard.img
```

Build Settings, Launcher2, SystemUI and crusty into `work/apps/`:

```bash
tools/build-apps.sh
```

Put the apps, the disabled packages, the keymap and the settings into the cards /data:

```bash
tools/mod-data.py
```

Turn golden mode into the crusty maintenance mode:

```bash
tools/mod-golden.py
```

Tell u-boot to boot into it next time:

```bash
tools/ubootenv.py golden
```

Pack it all up, gives you `out/sdcard-mod.img`:

```bash
tools/pack.sh
```

And write it to the card, CHECK THE DEVICE NAME TWICE:

```bash
tools/flash.sh --incremental out/sdcard-mod.img /dev/sdX
```

Now the card goes back into the panel together with the stick, it boots into golden mode ("Crusty Recovery (Golden Mode)": yellow title bar, a log panel, then the actions) and you tap "Back up eMMC to USB stick". Wait for "backup DONE + verified", then "Shut down" (it saves the logs to the stick first).

Back on the PC (the folders on the stick are named after the panel's ethernet MAC, `crusty-emmc-backup-00107FB9C887`, the same one that is printed on the panel, the clock is useless in golden mode; a second backup of the same panel gets `-2`) copy everything from the `crusty-emmc-backup-*` folder on the stick into `work/emmc-backup/`, then verify and unpack it:

```bash
tools/extract-emmc.py work/emmc-backup work/emmc
```

Build su:

```bash
tools/build-su.sh
```

Build Dropbear (skip it and you just dont get ssh):

```bash
tools/build-dropbear.sh
```

Get Chromium:

```bash
tools/fetch-chromium.sh
```

Build the eMMC update, gives you `out/crusty-emmc-update/` and `out/crusty-emmc-restore/`:

```bash
tools/build-emmc.py
```

Yeet both onto the stick (only writes the chunks that differ and reads everything back after):

```bash
tools/sync-stick.py /media/$USER/STICK out/crusty-emmc-update out/crusty-emmc-restore
```

Stick into the panel, golden mode again, tap "Update eMMC from USB stick", wait for "install DONE + verified" and then "Reboot to the normal system".

> Note : `setup.sh` also rebuilds and rewrites the card at this point (read-data, the card steps from above again, flash), because the card holds the panels /data and stays in there for good.

<br>

Some extras:

- this pulls /data off a card thats been in use so a rebuild keeps what you set up on the panel:

```bash
tools/read-data.sh /dev/sdX
```

- this runs the maintenance mode script on the PC against fake partitions, for when you touched `app/golden/` and would like to not find out on the real eMMC:

```bash
tests/golden/run.sh
```

- same thing but for the install/restore part:

```bash
tests/golden/install.sh
```

- and for the rest (save logs, ssh keys, clear apps' data, shut down / stay in golden mode):

```bash
tests/golden/actions.sh
```
