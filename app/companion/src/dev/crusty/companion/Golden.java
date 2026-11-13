package dev.crusty.companion;

import android.content.Context;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
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

    private static long sRequestedAt;
    private static String sStatusAtRequest;
    private static String sLocalError;

    static boolean active() {
        String m = CrustyService.read(new File("/proc/mounts"));
        if (m == null) return false;
        for (String l : m.split("\n")) {
            String[] f = l.split(" ");
            if (f.length > 1 && "/system".equals(f[1]) && f[0].contains("mmcblk0p2")) return true;
        }
        return false;
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

    private static String logTail(int lines) {
        String[] l = read(LOG).split("\n");
        StringBuilder sb = new StringBuilder();
        for (int i = Math.max(0, l.length - lines); i < l.length; i++) sb.append(l[i]).append('\n');
        return sb.toString().trim();
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

    private static float sp(Context c, float v) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, c.getResources().getDisplayMetrics());
    }

    private static TextView text(Context c, float size, int color) {
        TextView t = new TextView(c);
        t.setTextSize(size);
        t.setTextColor(color);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    // big button, if confirm != null it wants a second tap within 5 s (for the ones that can ruin your day)
    private static Button button(final Context c, final String label, final String confirm, final Runnable action) {
        final Button b = new Button(c);
        b.setText(label);
        b.setTextSize(24);
        b.setAllCaps(false);
        b.setMinHeight(110);
        b.setPadding(30, 20, 30, 20);
        final Handler h = new Handler();
        final boolean[] armed = { false };
        final Runnable disarm = new Runnable() {
            public void run() { armed[0] = false; b.setText(label); }
        };
        b.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                if (confirm != null && !armed[0]) {
                    armed[0] = true;
                    b.setText("Tap again to confirm: " + confirm);
                    h.postDelayed(disarm, 5000);
                    return;
                }
                h.removeCallbacks(disarm);
                disarm.run();
                action.run();
            }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 12, 0, 12);
        b.setLayoutParams(lp);
        return b;
    }

    static void showBanner(final Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setGravity(Gravity.CENTER_HORIZONTAL);
        l.setPadding(48, 30, 48, 30);

        TextView title = text(c, 40, Color.rgb(0xff, 0xc8, 0x2e));
        title.setText("Mmmm yes, this is golden mode.");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        l.addView(title);

        TextView sub = text(c, 16, Color.rgb(0xe0, 0xd0, 0xa0));
        sub.setText("crusty maintenance mode - /system from SD card p2 - crestrons golden scripts are disabled");
        l.addView(sub);

        final TextView status = text(c, 24, Color.WHITE);
        status.setPadding(0, 24, 0, 8);
        l.addView(status);

        final ProgressBar bar = new ProgressBar(c, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(1000);
        bar.setVisibility(View.GONE);
        l.addView(bar, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 48));

        final TextView prog = text(c, 20, Color.rgb(0xff, 0xe0, 0x90));
        l.addView(prog);

        final Runnable[] refresh = new Runnable[1];
        l.addView(button(c, "Back up eMMC to USB stick", null, new Runnable() {
            public void run() { request("backup"); status.setText("request sent - waiting for the golden script ..."); }
        }));
        l.addView(button(c, "Install crusty eMMC update from USB", "write the eMMC", new Runnable() {
            public void run() { request("install"); status.setText("request sent - waiting for the golden script ..."); }
        }));
        l.addView(button(c, "Restore original eMMC from USB", "restore the eMMC", new Runnable() {
            public void run() { request("restore"); status.setText("request sent - waiting for the golden script ..."); }
        }));
        l.addView(button(c, "Save logs & shut down", "shut down", new Runnable() {
            public void run() {
                CrustyService.event("golden: save logs + shut down");
                CrustyService.sh("sync");
                request("shutdown");
                status.setText("request sent - waiting for the golden script ...");
            }
        }));
        l.addView(button(c, "Reboot to the normal system", "reboot", new Runnable() {
            public void run() {
                CrustyService.event("golden: reboot to normal");
                ((PowerManager) c.getSystemService(Context.POWER_SERVICE)).reboot(null);
            }
        }));

        final TextView log = text(c, 14, Color.rgb(0xc0, 0xb8, 0x98));
        log.setTypeface(Typeface.MONOSPACE);
        log.setPadding(0, 20, 0, 0);
        l.addView(log);

        ScrollView sv = new ScrollView(c);
        sv.setBackgroundColor(Color.rgb(0x3a, 0x2c, 0x00));
        sv.addView(l);

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_SYSTEM_ALERT,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_FULLSCREEN,
                PixelFormat.OPAQUE);
        lp.setTitle("crusty-golden");
        try {
            ((WindowManager) c.getSystemService(Context.WINDOW_SERVICE)).addView(sv, lp);
        } catch (Exception e) {
            CrustyService.event("golden: banner failed: " + e);
            return;
        }
        final Handler h = new Handler();
        refresh[0] = new Runnable() {
            public void run() {
                String st = statusText();
                status.setText(st);
                boolean bad = st.startsWith("ERROR") || st.startsWith("WARNING") || st.contains("FAILED");
                status.setTextColor(bad ? Color.rgb(0xff, 0x70, 0x60) : Color.WHITE);
                int[] pr = new int[1];
                String ps = progress(pr, read(STATUS));
                bar.setVisibility(pr[0] >= 0 ? View.VISIBLE : View.GONE);
                if (pr[0] >= 0) bar.setProgress(pr[0]);
                prog.setText(ps != null ? ps : "");
                log.setText(logTail(5));
                h.postDelayed(this, 1000);
            }
        };
        h.post(refresh[0]);
    }
}
