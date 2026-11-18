package dev.crusty.companion;

import android.content.Context;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Handler;
import android.os.SystemClock;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import java.io.File;
import java.io.RandomAccessFile;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

// golden (maintenance) mode: the panel booted crestrons fallback, so /system is SD card p2 instead of the internal eMMC.
// crustys golden script (app/golden/crestInit.sh) runs as root there, this banner shows its status, the progress of the long operations and sends it requests.
final class Golden {
    private Golden() { }

    static final File STATUS = new File("/data/crusty/golden-status");
    static final File REQUEST = new File("/data/crusty/golden-request");
    static final File LOG = new File("/data/crusty/golden.log");
    static final File SSH_FLAG = new File("/data/crusty/golden-ssh");   // there while the golden script's dropbear runs
    static final File VERBOSE_FLAG = new File("/data/crusty/golden-verbose");   // there while u-boot's initargs carry the verbose console

    private static long sRequestedAt;
    private static String sStatusAtRequest;
    private static String sLocalError;

    private static Boolean sActive;

    // /system never changes under a running process, so ask /proc/mounts once (this gets called from key and LED code too)
    static synchronized boolean active() {
        if (sActive == null) {
            sActive = false;
            String m = CrustyService.read(new File("/proc/mounts"));
            if (m != null) {
                for (String l : m.split("\n")) {
                    String[] f = l.split(" ");
                    if (f.length > 1 && "/system".equals(f[1]) && f[0].contains("mmcblk0p2")) sActive = true;
                }
            }
        }
        return sActive;
    }

    // the banner cant do root work itself so it begs crustys golden script (root) to do it
    static void request(String what) {
        CrustyService.event("golden: request " + what);
        sStatusAtRequest = read(STATUS);
        sRequestedAt = SystemClock.elapsedRealtime();
        sLocalError = null;
        if (!CrustyService.write(REQUEST, what + "\n", false)) {
            sLocalError = "ERROR: couldnt write " + REQUEST + " (permissions?)";
            CrustyService.event("golden: " + sLocalError);
        }
    }

    private static String read(File f) {
        String s = CrustyService.read(f);
        return s == null ? "" : s.trim();
    }

    // the scripts status line, or our own "request sent" / "script not responding" feedback on top of it
    private static String statusText() {
        String s = read(STATUS);
        if (sLocalError != null) return sLocalError;
        if (sRequestedAt > 0 && s.equals(sStatusAtRequest)) {
            long ms = SystemClock.elapsedRealtime() - sRequestedAt;
            if (ms > 8000) {
                return "WARNING: the golden script isnt reacting to the request (is it even running?)\nlast status: " + s;
            }
            return "request sent - waiting for the golden script ...";
        }
        if (!s.equals(sStatusAtRequest)) sRequestedAt = 0;
        return s.length() > 0 ? s : "waiting for the golden script ... (no " + STATUS + " yet)";
    }

    // the end of golden.log, the file keeps growing over many golden sessions so only the last 32 KiB get read
    private static String logTail(int lines) {
        try {
            RandomAccessFile f = new RandomAccessFile(LOG, "r");
            try {
                long len = f.length(), start = Math.max(0, len - 32768);
                byte[] b = new byte[(int) (len - start)];
                f.seek(start);
                f.readFully(b);
                String[] l = new String(b, "UTF-8").split("\n");
                StringBuilder sb = new StringBuilder();
                for (int i = Math.max(start > 0 ? 1 : 0, l.length - lines); i < l.length; i++) sb.append(l[i]).append('\n');
                return sb.toString().trim();
            } finally {
                f.close();
            }
        } catch (Exception e) {
            return "";
        }
    }

    // ---------------------------------------------------------------- progress
    // measured with the kernels block statistics (/sys/block/<dev>/stat, world readable) so it needs neither access to the sticks files nor any help from the root script.

    static long blockStat(String dev, int field) {   // field 2 = sectors read, 6 = sectors written
        String st = CrustyService.read(new File("/sys/block/" + dev + "/stat"));
        if (st == null) return -1;
        String[] f = st.trim().split("\\s+");
        try { return f.length > field ? Long.parseLong(f[field]) : -1; } catch (NumberFormatException e) { return -1; }
    }

    static String stickDev() {
        for (String d : new String[] { "sda", "sdb", "sdc", "sdd" }) {
            if (new File("/sys/block/" + d + "/stat").exists()) return d;
        }
        return null;
    }

    static long emmcBytes() {
        String p = CrustyService.read(new File("/proc/partitions"));
        if (p == null) return 0;
        for (String l : p.split("\n")) {
            String[] f = l.trim().split("\\s+");
            if (f.length == 4 && "mmcblk1".equals(f[3])) {
                try { return Long.parseLong(f[2]) * 1024L; } catch (NumberFormatException e) { return 0; }
            }
        }
        return 0;
    }

    private static final Pattern KIB = Pattern.compile("\\((\\d+) KiB\\)");
    private static final Pattern CHUNK = Pattern.compile("chunk (\\d+)/(\\d+) chunks");
    private static String sPhase;
    private static long sPhaseBase, sLastBytes = -1, sLastAt, sRateBps;

    // progress 0..1000 in out[0] (-1 = no bar) + text, depending on which phase the status line is in.
    // every string matched in here has to be spelled exactly like app/golden/crestInit.sh writes it, reword one side only and the bar goes bye bye.
    static String progress(int[] out, String status) {
        out[0] = -1;
        String dev, label;
        int field;
        long total;
        Matcher cm = CHUNK.matcher(status);
        if (cm.find()) {                      // incremental eMMC write: the script counts itself
            long n = Long.parseLong(cm.group(1)), t = Math.max(1, Long.parseLong(cm.group(2)));
            out[0] = (int) Math.min(1000, n * 1000 / t);
            sPhase = null;
            return String.format(Locale.US, "%s chunk %d of %d (%d%%)",
                    status.startsWith("writing") ? "writing" : "comparing", n, t, out[0] / 10);
        }
        Matcher m = KIB.matcher(status);
        long kib = m.find() ? Long.parseLong(m.group(1)) : 0;
        if (status.contains("copying the eMMC")) {
            dev = stickDev(); field = 6; total = emmcBytes(); label = "written to the USB stick";
        } else if (status.contains("verifying - reading the backup back")) {
            dev = stickDev(); field = 2; total = emmcBytes(); label = "verified (read back from the stick)";
        } else if (status.contains("checksum of the eMMC")) {
            sPhase = null;
            return "waiting for the eMMCs own checksum ...";
        } else if (status.startsWith("checking ") && status.contains("on the stick") && kib > 0) {
            dev = stickDev(); field = 2; total = kib * 1024; label = "checked on the stick";
        } else if (status.startsWith("checking the current") && kib > 0) {
            dev = "mmcblk1"; field = 2; total = kib * 1024; label = "checked on the eMMC";
        } else if (status.startsWith("writing ") && kib > 0) {
            dev = "mmcblk1"; field = 6; total = kib * 1024; label = "written to the eMMC";
        } else if (status.startsWith("reading back") && kib > 0) {
            dev = "mmcblk1"; field = 2; total = kib * 1024; label = "read back from the eMMC";
        } else {
            sPhase = null;
            return null;
        }
        if (dev == null || total <= 0) return null;
        long sectors = blockStat(dev, field);
        if (sectors < 0) return null;
        if (!status.equals(sPhase)) {          // new phase (or the banner got restarted mid phase)
            sPhase = status;
            sPhaseBase = sectors;
            sLastBytes = -1;
            sRateBps = 0;
        }
        long done = Math.min(total, (sectors - sPhaseBase) * 512L);
        long now = SystemClock.elapsedRealtime();
        if (sLastBytes >= 0 && now > sLastAt && done >= sLastBytes) {
            long r = (done - sLastBytes) * 1000L / Math.max(1, now - sLastAt);
            sRateBps = sRateBps == 0 ? r : (sRateBps * 4 + r) / 5;   // smoothed
        }
        sLastBytes = done;
        sLastAt = now;
        out[0] = (int) Math.min(1000, done * 1000L / total);
        StringBuilder sb = new StringBuilder(String.format(Locale.US, "%s: %.2f / %.2f GiB (%d%%)",
                label, done / 1073741824.0, total / 1073741824.0, out[0] / 10));
        if (done < total && sRateBps > 0) {
            sb.append(String.format(Locale.US, " - %.1f MB/s - ~%d min left",
                    sRateBps / 1e6, Math.max(1, (total - done) / sRateBps / 60)));
        }
        return sb.toString();
    }

    // ---------------------------------------------------------------- UI
    // looks like the crusty app (dark list, one row per action) with a yellow title bar, then the log panel, then the actions

    private static final int YELLOW = Color.rgb(0xff, 0xc8, 0x2e);
    private static final int BG = Color.rgb(0x21, 0x21, 0x21);
    private static final int PRESSED = Color.rgb(0x3d, 0x3d, 0x3d);
    private static final int DIVIDER = Color.rgb(0x42, 0x42, 0x42);
    private static final int SUBTEXT = Color.rgb(0xb0, 0xb0, 0xb0);
    private static final int WARN = Color.rgb(0xff, 0xb7, 0x4d);
    private static final int BAD = Color.rgb(0xff, 0x70, 0x60);

    private static LinearLayout sList;
    private static TextView sStatus;
    private static CheckBox sSshBox, sVerboseBox, sScreenBox;   // only while the "more" list is showing
    private static boolean sStay;          // "stay in golden mode" next to Shut down
    private static boolean sRawInstall, sRawRestore;   // "Flash RAW (slow)" next to Update / Restore

    private static final String BRIGHTNESS_PREF = "golden.brightness";   // 0 = never touched, then android decides (and golden mode is dim)

    private static int backlight() {
        String v = CrustyService.read(Blanker.BACKLIGHT);
        try { return v == null ? 128 : Integer.parseInt(v.trim()); } catch (NumberFormatException e) { return 128; }
    }

    // straight to the backlight like Blanker does, android alone left golden mode dim as hell. kept in a pref so it survives golden reboots
    private static void applyBrightness(Context c) {
        int want = Prefs.num(c, BRIGHTNESS_PREF, 0);
        if (want > 0 && backlight() != want) Blanker.writeBacklight(String.valueOf(want));
    }

    private static View brightnessRow(final Context c) {
        LinearLayout r = new LinearLayout(c);
        r.setOrientation(LinearLayout.VERTICAL);
        r.setPadding(dp(c, 16), dp(c, 10), dp(c, 16), dp(c, 10));
        final TextView t = label(c, 18, Color.WHITE);
        r.addView(t);
        SeekBar bar = new SeekBar(c);
        bar.setMax(245);   // 10..255, 0 would be a black screen you cant get back from without the slider
        int cur = Math.max(10, Math.min(255, Prefs.num(c, BRIGHTNESS_PREF, backlight())));
        bar.setProgress(cur - 10);
        t.setText("Brightness " + cur * 100 / 255 + "%");
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar b, int progress, boolean fromUser) {
                int v = progress + 10;
                t.setText("Brightness " + v * 100 / 255 + "%");
                if (!fromUser) return;
                Prefs.get(c).edit().putString(BRIGHTNESS_PREF, String.valueOf(v)).apply();
                Blanker.writeBacklight(String.valueOf(v));
            }
            public void onStartTrackingTouch(SeekBar b) { }
            public void onStopTrackingTouch(SeekBar b) { }
        });
        r.addView(bar);
        return r;
    }

    private static final int DISABLE_BACK = 0x00400000;   // android.app.StatusBarManager, hidden

    // no shade, no notification icons, and the nav bar buttons (back, home, recents) are taken away even if the bar itself is still there.
    // SystemUI may reset that so the tick below repeats it. the bar itself goes away via Tweaks.applyBars (crusty_navbar), the side buttons are dead in ButtonService, their leds are off via LedController.
    private static void hideShade(Context c) {
        Kiosk.disableStatusBar(c, Kiosk.DISABLE_EXPAND | Kiosk.DISABLE_NOTIFICATION_ICONS | Kiosk.DISABLE_NOTIFICATION_ALERTS
                | Kiosk.DISABLE_HOME | Kiosk.DISABLE_RECENT | DISABLE_BACK);
    }

    private static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    private static TextView label(Context c, float sp, int color) {
        TextView t = new TextView(c);
        t.setTextSize(sp);
        t.setTextColor(color);
        return t;
    }

    // one action row: title + summary, optional view on the right. confirm != null wants a second tap within 5 s (for the ones that can ruin your day)
    private static View row(final Context c, String title, String summary, final String confirm, View right, final Runnable action) {
        LinearLayout r = new LinearLayout(c);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setMinimumHeight(dp(c, 64));
        r.setPadding(dp(c, 16), dp(c, 8), dp(c, 16), dp(c, 8));
        StateListDrawable bg = new StateListDrawable();
        bg.addState(new int[] { android.R.attr.state_pressed }, new ColorDrawable(PRESSED));
        bg.addState(new int[0], new ColorDrawable(BG));
        r.setBackgroundDrawable(bg);
        r.setClickable(true);

        LinearLayout texts = new LinearLayout(c);
        texts.setOrientation(LinearLayout.VERTICAL);
        TextView t = label(c, 18, Color.WHITE);
        t.setText(title);
        texts.addView(t);
        final TextView sub = label(c, 14, SUBTEXT);
        sub.setText(summary);
        sub.setVisibility(summary == null ? View.GONE : View.VISIBLE);
        texts.addView(sub);
        r.addView(texts, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        if (right != null) r.addView(right);

        final String idle = summary;
        final Handler h = new Handler();
        final boolean[] armed = { false };
        final Runnable disarm = new Runnable() {
            public void run() {
                armed[0] = false;
                sub.setText(idle);
                sub.setTextColor(SUBTEXT);
                sub.setVisibility(idle == null ? View.GONE : View.VISIBLE);
            }
        };
        r.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                if (confirm != null && !armed[0]) {
                    armed[0] = true;
                    sub.setText("Tap again to confirm: " + confirm);
                    sub.setTextColor(WARN);
                    sub.setVisibility(View.VISIBLE);
                    h.postDelayed(disarm, 5000);
                    return;
                }
                h.removeCallbacks(disarm);
                disarm.run();
                action.run();
            }
        });
        return r;
    }

    private static void add(Context c, View row) {
        sList.addView(row);
        View d = new View(c);
        d.setBackgroundColor(DIVIDER);
        sList.addView(d, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1));
    }

    // "Flash RAW (slow)": no incremental write, every partition gets rewritten completely (flaky flash debugging)
    private static CheckBox rawBox(Context c, final boolean install) {
        CheckBox b = new CheckBox(c);
        b.setText("Flash RAW (slow)");
        b.setTextColor(Color.WHITE);
        b.setTextSize(14);
        b.setChecked(install ? sRawInstall : sRawRestore);
        b.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            public void onCheckedChanged(android.widget.CompoundButton v, boolean on) {
                if (install) sRawInstall = on; else sRawRestore = on;
            }
        });
        return b;
    }

    private static Runnable act(final String what) {
        return new Runnable() {
            public void run() {
                request(what);
                sStatus.setText("request sent - waiting for the golden script ...");
            }
        };
    }

    private static void showMain(final Context c) {
        sList.removeAllViews();
        sSshBox = null;
        sVerboseBox = null;
        sScreenBox = null;
        add(c, row(c, "Back up eMMC to USB stick", "copies the whole internal eMMC to the stick and verifies it, 5-10 min", null, null, act("backup")));
        add(c, row(c, "Update eMMC from USB stick", "writes the crusty eMMC update (crusty-emmc-update/ on the stick), only what changed unless RAW", "write the eMMC", rawBox(c, true), new Runnable() {
            public void run() { act(sRawInstall ? "install raw" : "install").run(); }
        }));
        add(c, row(c, "Save logs to USB stick", "golden.log, crusty logs, dmesg and logcat", null, null, act("savelogs")));
        add(c, row(c, "Reboot to the normal system", "saves the logs to the USB stick first", "reboot", null, act("reboot")));
        CheckBox stay = new CheckBox(c);
        stay.setText("Stay in golden mode");
        stay.setTextColor(Color.WHITE);
        stay.setTextSize(14);
        stay.setChecked(sStay);
        stay.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            public void onCheckedChanged(android.widget.CompoundButton b, boolean on) { sStay = on; }
        });
        add(c, row(c, "Shut down", "saves the logs to the USB stick first - ticked: the next boot is golden mode again", "shut down", stay, new Runnable() {
            public void run() {
                CrustyService.event("golden: shut down, stay in golden=" + sStay);
                act(sStay ? "shutdown stay" : "shutdown").run();
            }
        }));
        add(c, row(c, "More >", "brightness, restore, network, ssh, system info, resets", null, null, new Runnable() {
            public void run() { showMore(c); }
        }));
    }

    private static void showMore(final Context c) {
        sList.removeAllViews();
        add(c, row(c, "< Back", null, null, null, new Runnable() {
            public void run() { showMain(c); }
        }));
        add(c, brightnessRow(c));
        add(c, row(c, "Restore original eMMC from USB stick", "writes the original images back (crusty-emmc-restore/ on the stick), only what changed unless RAW", "restore the eMMC", rawBox(c, false), new Runnable() {
            public void run() { act(sRawRestore ? "restore raw" : "restore").run(); }
        }));
        add(c, row(c, "Update recovery from USB stick", "installs the golden script, tools and the crusty app from crusty-recovery-update/ on the stick, then reboot to golden mode", "update the recovery", null, act("recovery")));
        add(c, row(c, "Reboot to golden mode", "saves the logs, reboots into this recovery again (runs a freshly updated one)", "reboot", null, act("reboot stay")));
        add(c, row(c, "Network info", "link state, addresses, routes, DNS", null, null, act("netinfo")));
        add(c, row(c, "Start network", "runs Crestron's AndroidEthInit (static IP or DHCP, as the panel was set up)", null, null, act("network")));
        sSshBox = new CheckBox(c);
        sSshBox.setClickable(false);
        sSshBox.setFocusable(false);
        sSshBox.setChecked(SSH_FLAG.exists());
        add(c, row(c, "SSH server", "key login as root on port 22, same keys as the normal system", null, sSshBox, new Runnable() {
            public void run() { act(SSH_FLAG.exists() ? "sshstop" : "sshstart").run(); }
        }));
        add(c, row(c, "Import SSH keys from USB stick", "adds authorized_keys / *.pub from the root of the stick", null, null, act("sshkeys")));
        sVerboseBox = new CheckBox(c);
        sVerboseBox.setClickable(false);
        sVerboseBox.setFocusable(false);
        sVerboseBox.setChecked(VERBOSE_FLAG.exists());
        add(c, row(c, "Verbose boot (serial console)", "kernel and init messages on the UART (115200 baud, no output on the screen) in every boot until you untick it", null, sVerboseBox, new Runnable() {
            public void run() { act(VERBOSE_FLAG.exists() ? "verboseoff" : "verboseon").run(); }
        }));
        sScreenBox = new CheckBox(c);
        sScreenBox.setClickable(false);
        sScreenBox.setFocusable(false);
        sScreenBox.setChecked(BootConsole.wanted());
        add(c, row(c, "Verbose boot on screen", "normal boots show the kernel log full screen over the boot animation, from about when Android starts until it is booted (tap to close). the first seconds of the kernel are serial only", null, sScreenBox, new Runnable() {
            public void run() { act(BootConsole.wanted() ? "verbosescreenoff" : "verbosescreenon").run(); }
        }));
        add(c, row(c, "System info", "kernel, memory, disks, USB devices", null, null, act("sysinfo")));
        add(c, row(c, "U-Boot environment", "boot_retry, golden flags and the rest", null, null, act("ubootenv")));
        add(c, row(c, "Clear apps' data", "empties the data of all apps (not the apps, crusty or the settings database)", "clear the data of all apps", null, act("cleardata")));
        add(c, row(c, "Reset crusty settings & PIN", "crusty's own settings back to defaults, removes the PIN", "reset crusty", null, act("resetcrusty")));
    }

    static void showBanner(final Context c) {
        LinearLayout root = new LinearLayout(c);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        // no status bar / nav bar here: the window sits above them (TYPE_SYSTEM_ERROR + NO_LIMITS below), this also asks them to hide and the shade is disabled
        root.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        hideShade(c);
        applyBrightness(c);

        TextView title = label(c, 20, Color.BLACK);
        title.setText("Crusty Recovery (Golden Mode)");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setGravity(Gravity.CENTER_VERTICAL);
        title.setPadding(dp(c, 16), 0, dp(c, 16), 0);
        title.setBackgroundColor(YELLOW);
        root.addView(title, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(c, 56)));

        // fixed log panel, sticks to the end unless you scroll up
        final TextView log = label(c, 12, Color.rgb(0xc8, 0xc8, 0xc8));
        log.setTypeface(Typeface.MONOSPACE);
        log.setPadding(dp(c, 12), dp(c, 6), dp(c, 12), dp(c, 6));
        final ScrollView logScroll = new ScrollView(c);
        logScroll.setBackgroundColor(Color.rgb(0x12, 0x12, 0x12));
        logScroll.addView(log);
        int logHeight = Math.max(dp(c, 110), c.getResources().getDisplayMetrics().heightPixels * 27 / 100);
        root.addView(logScroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, logHeight));

        LinearLayout strip = new LinearLayout(c);
        strip.setOrientation(LinearLayout.VERTICAL);
        strip.setPadding(dp(c, 16), dp(c, 6), dp(c, 16), dp(c, 6));
        sStatus = label(c, 15, Color.WHITE);
        strip.addView(sStatus);
        final ProgressBar bar = new ProgressBar(c, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(1000);
        bar.setVisibility(View.GONE);
        strip.addView(bar, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(c, 12)));
        final TextView prog = label(c, 13, YELLOW);
        prog.setVisibility(View.GONE);
        strip.addView(prog);
        root.addView(strip);

        sList = new LinearLayout(c);
        sList.setOrientation(LinearLayout.VERTICAL);
        ScrollView sv = new ScrollView(c);
        sv.addView(sList);
        root.addView(sv, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        showMain(c);

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_FULLSCREEN,
                PixelFormat.OPAQUE);
        lp.setTitle("crusty-golden");
        try {
            ((WindowManager) c.getSystemService(Context.WINDOW_SERVICE)).addView(root, lp);
        } catch (Exception e) {
            CrustyService.event("golden: banner failed: " + e);
            return;
        }
        final Handler h = new Handler();
        final String[] shown = { null };
        h.post(new Runnable() {
            private int ticks;
            public void run() {
                if (ticks++ % 5 == 0) {
                    hideShade(c);
                    Blanker.writeLed("0");   // side button leds stay dark
                    applyBrightness(c);
                }
                String st = statusText();
                sStatus.setText(st);
                boolean bad = st.startsWith("ERROR") || st.startsWith("WARNING") || st.contains("FAILED");
                sStatus.setTextColor(bad ? BAD : Color.WHITE);
                int[] pr = new int[1];
                String ps = progress(pr, read(STATUS));
                bar.setVisibility(pr[0] >= 0 ? View.VISIBLE : View.GONE);
                if (pr[0] >= 0) bar.setProgress(pr[0]);
                prog.setText(ps != null ? ps : "");
                prog.setVisibility(ps != null ? View.VISIBLE : View.GONE);
                if (sSshBox != null) sSshBox.setChecked(SSH_FLAG.exists());
                if (sVerboseBox != null) sVerboseBox.setChecked(VERBOSE_FLAG.exists());
                if (sScreenBox != null) sScreenBox.setChecked(BootConsole.wanted());

                String t = logTail(300);
                if (!t.equals(shown[0])) {
                    View inner = logScroll.getChildAt(0);
                    boolean atBottom = inner == null || logScroll.getScrollY() + logScroll.getHeight() >= inner.getHeight() - dp(c, 24);
                    shown[0] = t;
                    log.setText(t);
                    if (atBottom) logScroll.post(new Runnable() {
                        public void run() { logScroll.fullScroll(View.FOCUS_DOWN); }
                    });
                }
                h.postDelayed(this, 1000);
            }
        });
    }
}
