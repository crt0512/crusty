package dev.crusty.companion;

import android.content.Context;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.view.View;
import android.view.WindowManager;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.util.ArrayList;

// "verbose boot on the screen": the kernel has no framebuffer console (no CONFIG_VT) and SurfaceFlinger owns the screen long before the first userland hook of ours runs,
// so this is the closest thing: as soon as the companion runs (early in system_server's boot) a full screen overlay on top of the boot animation shows the kernel log (dmesg, which includes init's lines) live.
// it goes away 8 s after boot_completed, or when you tap it. the earliest part of the boot (kernel, first seconds of init) is only in there as history, it cant be watched live, use the serial console for that.
// switched on with the flag file config/verbose_screen (golden mode -> More -> "Verbose boot on screen")
final class BootConsole {
    private BootConsole() { }

    static final File FLAG = new File(CrustyService.CONFIG, "verbose_screen");
    private static final int KEEP_LINES = 400;

    private static boolean sShown;

    static boolean wanted() {
        return FLAG.exists();
    }

    static synchronized void show(final Context c) {
        if (sShown) return;
        final Handler main = new Handler(Looper.getMainLooper());
        final TextView text = new TextView(c);
        text.setTypeface(Typeface.MONOSPACE);
        text.setTextSize(11);
        text.setTextColor(Color.rgb(0xc8, 0xc8, 0xc8));
        text.setPadding(12, 8, 12, 8);
        final ScrollView root = new ScrollView(c);
        root.setBackgroundColor(Color.BLACK);
        root.addView(text);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_FULLSCREEN | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                PixelFormat.OPAQUE);
        lp.setTitle("crusty-bootconsole");
        final WindowManager wm = (WindowManager) c.getSystemService(Context.WINDOW_SERVICE);
        try {
            wm.addView(root, lp);
        } catch (Exception e) {
            CrustyService.event("bootconsole: " + e);
            return;
        }
        sShown = true;
        CrustyService.event("bootconsole: shown");

        final boolean[] stop = { false };
        root.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { stop[0] = true; }
        });
        new Thread("crusty-bootconsole") {
            public void run() {
                long doneAt = 0;
                while (!stop[0]) {
                    final CharSequence t = render(dmesg());
                    main.post(new Runnable() {
                        public void run() {
                            text.setText(t);
                            root.post(new Runnable() {
                                public void run() { root.fullScroll(View.FOCUS_DOWN); }
                            });
                        }
                    });
                    if (bootCompleted()) {
                        if (doneAt == 0) doneAt = System.currentTimeMillis();
                        if (System.currentTimeMillis() - doneAt > 8000) break;
                    }
                    try { Thread.sleep(700); } catch (InterruptedException e) { break; }
                }
                main.post(new Runnable() {
                    public void run() {
                        try { wm.removeView(root); } catch (Exception e) { }
                        sShown = false;
                        CrustyService.event("bootconsole: gone");
                    }
                });
            }
        }.start();
    }

    private static boolean bootCompleted() {
        try {
            Method m = Class.forName("android.os.SystemProperties").getMethod("get", String.class);
            return "1".equals(m.invoke(null, "sys.boot_completed"));
        } catch (Exception e) {
            return false;
        }
    }

    private static ArrayList<String> dmesg() {
        ArrayList<String> lines = new ArrayList<String>();
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[] { "dmesg" });
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            for (String l; (l = r.readLine()) != null; ) {
                lines.add(l);
                if (lines.size() > KEEP_LINES) lines.remove(0);
            }
            p.waitFor();
        } catch (Exception e) {
            lines.add("dmesg failed: " + e);
        } finally {
            if (p != null) p.destroy();
        }
        return lines;
    }

    // "<3>[    1.234@0] text": the <n> is the kernel log level, errors red and warnings yellow
    private static CharSequence render(ArrayList<String> lines) {
        SpannableStringBuilder sb = new SpannableStringBuilder();
        for (String l : lines) {
            int color = 0;
            if (l.length() > 3 && l.charAt(0) == '<' && l.charAt(2) == '>' && Character.isDigit(l.charAt(1))) {
                int lvl = l.charAt(1) - '0';
                color = lvl <= 3 ? Color.rgb(0xff, 0x70, 0x60) : lvl == 4 ? Color.rgb(0xff, 0xc8, 0x2e) : 0;
                l = l.substring(3);
            } else if (l.length() > 5 && l.charAt(0) == '<' && l.indexOf('>') > 0 && l.indexOf('>') < 5) {
                l = l.substring(l.indexOf('>') + 1);   // <14> and the like: init's own lines
            }
            int start = sb.length();
            sb.append(l).append('\n');
            if (color != 0) sb.setSpan(new ForegroundColorSpan(color), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return sb;
    }
}
