package dev.crusty.companion;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

// the side button leds
// brightness for all five at once is /sys/class/keypad_led/brightness (init chowns it to system), single leds on/off go through "onoff" ("led<n> <0|1>") which is root only unless crusty-boot.sh (eMMC update) chowned it to system
// awake: on | touch (lit for N seconds after a touch or button press) | off
// asleep (screen blanked): off | dim | on
// the "button leds on/off" action flips a manual off override while awake
final class LedController {
    private static LedController sInstance;

    private final Context mContext;
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private long mLastActivity = SystemClock.elapsedRealtime();
    private boolean mManualOff;
    private String mLastWritten;
    private String mLastMask = "";

    static synchronized LedController get(Context c) {
        if (sInstance == null) sInstance = new LedController(c.getApplicationContext());
        return sInstance;
    }

    private LedController(Context c) {
        mContext = c;
    }

    private final Runnable mApply = new Runnable() {
        public void run() { apply(false); }
    };

    void onUserActivity() {
        mLastActivity = SystemClock.elapsedRealtime();
        if ("touch".equals(Prefs.str(mContext, Prefs.LED_AWAKE, "on"))) apply(false);
    }

    void toggleManualOff() {
        mManualOff = !mManualOff;
        apply(false);
    }

    int desiredLevel() {
        int level = clamp(Prefs.num(mContext, Prefs.LED_LEVEL, 128));
        if (Blanker.blanked()) {
            String m = Prefs.str(mContext, Prefs.LED_SLEEP, "off");
            if ("on".equals(m)) return level;
            if ("dim".equals(m)) return clamp(Prefs.num(mContext, Prefs.LED_SLEEP_LEVEL, 10));
            return 0;
        }
        if (mManualOff) return 0;
        String m = Prefs.str(mContext, Prefs.LED_AWAKE, "on");
        if ("off".equals(m)) return 0;
        if ("touch".equals(m)) {
            long ms = Prefs.num(mContext, Prefs.LED_TOUCH_SECONDS, 10) * 1000L;
            long left = mLastActivity + ms - SystemClock.elapsedRealtime();
            mHandler.removeCallbacks(mApply);
            if (left <= 0) return 0;
            mHandler.postDelayed(mApply, left + 50);
        }
        return level;
    }

    // force = write 0 first and then the level even if nothing changed, the leds blink once
    synchronized void apply(boolean force) {
        String want = String.valueOf(desiredLevel());
        String mask = "";
        for (int i = 1; i <= 5; i++) mask += ledEnabled(mContext, i) ? "1" : "0";
        if (!force && want.equals(mLastWritten) && mask.equals(mLastMask)) return;
        mLastMask = mask;
        if (force && !"0".equals(want)) Blanker.writeLed("0");
        boolean ok = Blanker.writeLed(want);
        if (!ok) CrustyService.event("leds: write " + want + " FAILED");
        // then every led on/off the way the user picked it (all on by default)
        if (!"0".equals(want)) {
            for (int i = 1; i <= 5; i++) setOnoff(i, ledEnabled(mContext, i) ? 1 : 0);
        }
        mLastWritten = want;
    }

    // ---- per led switch /sys/class/keypad_led/onoff, write only and root only until crusty-boot.sh chowns it
    // nobody tells us the input format, all the kernel does on bad input is whine "wrong control value, should be [led1, ... led5]" / "[0, 1]" into dmesg, so we try the candidates and take the one that adds no such whining
    static final java.io.File ONOFF = new java.io.File("/sys/class/keypad_led/onoff");
    static final String[] FORMATS = { "led%d %d", "led%d,%d", "led%d=%d", "led%d:%d", "%d %d" };
    static volatile String sOnoffFormat;          // null = unknown / not writable
    static volatile String sOnoffInfo = "not probed yet";

    private static int kernelComplaints() {
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[] { "dmesg" });
            java.io.BufferedReader r = new java.io.BufferedReader(new java.io.InputStreamReader(p.getInputStream()));
            int n = 0;
            for (String l; (l = r.readLine()) != null; ) if (l.contains("wrong control value")) n++;
            p.waitFor();
            return n;
        } catch (Exception e) {
            return -1;
        } finally {
            if (p != null) p.destroy();
        }
    }

    // the candidates get tried with "led 1 on" which is harmless, the winner lands in config/onoff_format so we dont do this dance on every boot
    static void probeOnoff() {
        if (!ONOFF.canWrite()) {
            sOnoffInfo = "onoff not writable (needs the eMMC boot hook)";
            CrustyService.event("leds: " + sOnoffInfo);
            return;
        }
        String pref = CrustyService.read(new java.io.File(CrustyService.CONFIG, "onoff_format"));
        if (pref != null && pref.trim().length() > 0) {
            sOnoffFormat = pref.trim();
            sOnoffInfo = "format \"" + sOnoffFormat + "\" (configured)";
            return;
        }
        for (String f : FORMATS) {
            int before = kernelComplaints();
            boolean wrote = CrustyService.write(ONOFF, String.format(java.util.Locale.US, f, 1, 1) + "\n", false);
            try { Thread.sleep(150); } catch (InterruptedException e) { }
            int after = kernelComplaints();
            CrustyService.event("leds: onoff probe \"" + f + "\": write " + (wrote ? "ok" : "failed")
                    + ", kernel complaints " + before + " -> " + after);
            if (wrote && before >= 0 && after == before) {
                sOnoffFormat = f;
                sOnoffInfo = "format \"" + f + "\" (probed)";
                CrustyService.write(new java.io.File(CrustyService.CONFIG, "onoff_format"), f + "\n", false);
                return;
            }
        }
        sOnoffInfo = "the kernel didnt like any format";
    }

    // led is 1..5, false when we dont know the format or cant write
    static boolean setOnoff(int led, int on) {
        String f = sOnoffFormat;
        if (f == null) return false;
        return CrustyService.write(ONOFF, String.format(java.util.Locale.US, f, led, on) + "\n", false);
    }

    static void setAllOnoff(int on) {
        if (sOnoffFormat == null) return;
        for (int i = 1; i <= 5; i++) setOnoff(i, on);
    }

    // kpled numbering (led1..led5) -> the button next to it, bottom to top
    static final String[] LED_BUTTONS = { null, "Down", "Up", "Lamp", "Home", "Power" };

    // per led switches: lit while awake / lit while the screen is off, all on by default
    static String ledKey(int led) { return "led.on." + led; }

    static String ledSleepKey(int led) { return "led.sleep_on." + led; }

    static boolean ledEnabled(Context c, int led) {
        return Prefs.bool(c, Blanker.blanked() ? ledSleepKey(led) : ledKey(led), true);
    }

    // blinks one led a few times so you can see which button it belongs to, then puts everything back
    void identify(final int led) {
        new Thread("crusty-led-identify") {
            public void run() {
                for (int k = 0; k < 4; k++) {
                    setOnoff(led, 0);
                    try { Thread.sleep(350); } catch (InterruptedException e) { }
                    setOnoff(led, 1);
                    try { Thread.sleep(350); } catch (InterruptedException e) { }
                }
                apply(true);
            }
        }.start();
    }

    private static int clamp(int v) {
        return Math.max(1, Math.min(255, v));
    }
}
