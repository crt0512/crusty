package dev.crusty.companion;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.database.ContentObserver;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Date;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

// the crusty companion service, everything that has to keep running in the background lives here
// holds a PARTIAL_WAKE_LOCK so the SoC never suspends, suspending stops crestrons watchdog petting and then the hardware watchdog reboots the panel as soon as the screen is turned off (no bueno)
// logcat goes to /data/crusty/logs/boot-NNN/ (SD card p6, survives power pulls), kernel log, led/screen state changes and periodic dumpsys snapshots land in the same folder
// keeps the side button leds lit while the screen is on, crestrons ui used to do that
// everything is plain files so you can read it offline straight from the SD card
public class CrustyService extends Service implements android.content.SharedPreferences.OnSharedPreferenceChangeListener {
    static final String TAG = "crusty";
    static final String ACTION_SNAPSHOT = "dev.crusty.companion.SNAPSHOT";
    static final File ROOT = new File("/data/crusty");
    static final File LOGS = new File(ROOT, "logs");
    static final File CONFIG = new File(ROOT, "config");
    static final File LED_DIR = new File("/sys/class/keypad_led");
    static final File BL_DIR = new File("/sys/class/backlight/aml-bl");
    static final int KEEP_BOOTS = 10;

    static volatile File sBootDir;
    static volatile String sLedState = "?";
    static volatile boolean sWakeLockHeld;

    private PowerManager.WakeLock mWakeLock;
    private Process mLogcat;
    private Handler mWorker;
    private final Map<String, String> mLastLed = new TreeMap<String, String>();
    private boolean mInteractive = true;

    private final BroadcastReceiver mScreenReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            mInteractive = Intent.ACTION_SCREEN_ON.equals(i.getAction());
            event("screen " + (mInteractive ? "ON" : "OFF"));
            if (mInteractive && !Blanker.blanked()) {
                LedController.get(c).apply(false);
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        PendingIntent pi = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), 0);
        Notification n = new Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setContentTitle("crusty")
                .setContentText("loggin to /data/crusty/logs and keeping the cpu awake")
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
        startForeground(1, n);

        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        mWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "crusty:nosuspend");
        mWakeLock.setReferenceCounted(false);
        if (!new File(CONFIG, "allow_suspend").exists()) {
            mWakeLock.acquire();
            sWakeLockHeld = true;
        }
        mInteractive = pm.isInteractive();

        sBootDir = newBootDir();
        event("service start, uptime=" + SystemClock.elapsedRealtime() / 1000 + "s, wakelock=" + sWakeLockHeld);
        if (Prefs.bool(this, Prefs.LOG_LOGCAT, true)) startLogcat();
        Prefs.get(this).registerOnSharedPreferenceChangeListener(this);

        HandlerThread t = new HandlerThread("crusty-worker");
        t.start();
        mWorker = new Handler(t.getLooper());
        mWorker.post(new Runnable() {          // find the per led switch format once
            public void run() { LedController.probeOnoff(); }
        });
        mWorker.post(mLedPoll);
        mWorker.post(mKernelLog);
        mWorker.postDelayed(new Runnable() {
            public void run() { snapshot("boot+20s"); }
        }, 20000);
        mWorker.postDelayed(mPeriodicSnapshot, 5 * 60 * 1000);

        final Handler main = new Handler();
        Tweaks.applyAll(this);
        ContentObserver retweak = new ContentObserver(main) {
            @Override
            public void onChange(boolean selfChange) { Tweaks.applyAll(CrustyService.this); }
        };
        for (String k : new String[] { "window_animation_scale", "transition_animation_scale",
                "animator_duration_scale", "policy_control", Tweaks.SETTING_NAVBAR }) {
            getContentResolver().registerContentObserver(Settings.Global.getUriFor(k), false, retweak);
        }

        NtpSync.start(this);   // the panels clock was never right -> SSL errors everywhere

        if (Golden.active()) {
            event("GOLDEN MODE: /system is SD card p2 (crusty maintenance mode)");
            Golden.showBanner(this);
        }

        // autostart / kiosk app after boot, only when the process starts during boot though, a service restart hours later shouldnt yoink you out of whatever you were doing
        if (SystemClock.elapsedRealtime() < 10 * 60 * 1000 && !Golden.active()) {
            main.postDelayed(new Runnable() {
                public void run() {
                    if (Kiosk.active(CrustyService.this)) {
                        event("boot: kiosk " + Kiosk.pkg(CrustyService.this));
                        Kiosk.apply(CrustyService.this);
                        Kiosk.bringToFront(CrustyService.this);
                    } else {
                        String p = Prefs.str(CrustyService.this, Prefs.AUTOSTART_PKG, "");
                        if (p.length() > 0) {
                            event("boot: autostart " + p);
                            Actions.launch(CrustyService.this, p);
                        }
                    }
                }
            }, 3000);
        }

        // androids own screen-off = kernel early-suspend = touch controller (and the side buttons with it) held in reset, the panel cant be woken after that
        // so the timeout stays pinned at "never" and Blanker does the screen off instead
        pinScreenTimeout();
        getContentResolver().registerContentObserver(
                Settings.System.getUriFor(Settings.System.SCREEN_OFF_TIMEOUT), false,
                new ContentObserver(new Handler()) {
                    @Override
                    public void onChange(boolean selfChange) { pinScreenTimeout(); }
                });

        IntentFilter f = new IntentFilter(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        registerReceiver(mScreenReceiver, f);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_SNAPSHOT.equals(intent.getAction())) {
            final String why = intent.getStringExtra("why");
            mWorker.post(new Runnable() {
                public void run() { snapshot(why != null ? why : "manual"); }
            });
        }
        return START_STICKY;
    }

    @Override
    public void onSharedPreferenceChanged(android.content.SharedPreferences sp, String key) {
        if (key == null) return;
        if (key.startsWith("tweak.") || key.startsWith("kiosk.")) Tweaks.applyAll(this);
        if (key.startsWith("time.")) NtpSync.start(this);
        if (key.equals(Prefs.LOG_LOGCAT)) {
            boolean on = Prefs.bool(this, Prefs.LOG_LOGCAT, true);
            if (on && mLogcat == null) startLogcat();
            if (!on && mLogcat != null) { mLogcat.destroy(); mLogcat = null; event("logcat logging off"); }
        }
    }

    @Override
    public void onDestroy() {
        event("service destroyed");
        Prefs.get(this).unregisterOnSharedPreferenceChangeListener(this);
        unregisterReceiver(mScreenReceiver);
        if (mLogcat != null) mLogcat.destroy();
        if (mWakeLock.isHeld()) mWakeLock.release();
        sWakeLockHeld = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    private void pinScreenTimeout() {
        if (new File(CONFIG, "allow_screen_timeout").exists()) return;
        int cur = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_OFF_TIMEOUT, -1);
        if (cur != Integer.MAX_VALUE) {
            Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_OFF_TIMEOUT, Integer.MAX_VALUE);
            event("screen_off_timeout " + cur + " -> never (android sleep would lock the touch controller)");
        }
    }

    // ------------------------------------------------------------------ logs

    private static File newBootDir() {
        LOGS.mkdirs();
        CONFIG.mkdirs();
        int max = 0;
        String[] names = LOGS.list();
        if (names != null) {
            Arrays.sort(names);
            for (String n : names) {
                if (n.startsWith("boot-")) {
                    try { max = Math.max(max, Integer.parseInt(n.substring(5))); } catch (NumberFormatException e) { }
                }
            }
            int boots = 0;
            for (String n : names) if (n.startsWith("boot-")) boots++;
            for (String n : names) {
                if (boots < KEEP_BOOTS) break;
                if (n.startsWith("boot-")) { rmrf(new File(LOGS, n)); boots--; }
            }
        }
        File d = new File(LOGS, String.format(Locale.US, "boot-%03d", max + 1));
        new File(d, "snapshots").mkdirs();
        write(new File(LOGS, "latest"), d.getName() + "\n", false);
        return d;
    }

    private void startLogcat() {
        try {
            mLogcat = Runtime.getRuntime().exec(new String[] {
                    "logcat", "-v", "threadtime", "-b", "main", "-b", "system", "-b", "events",
                    "-f", new File(sBootDir, "logcat.txt").getPath(), "-r", "4096", "-n", "8" });
        } catch (IOException e) {
            event("logcat failed: " + e);
        }
    }

    // one line into events.txt (wall clock + uptime, the wall clock lies until ntp fixed it) and into logcat
    static void event(String msg) {
        Log.i(TAG, msg);
        File d = sBootDir;
        if (d == null) return;
        String ts = new SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(new Date());
        write(new File(d, "events.txt"),
                ts + " [" + SystemClock.elapsedRealtime() / 1000 + "s] " + msg + "\n", true);
    }

    private final Runnable mKernelLog = new Runnable() {
        public void run() {
            if (Prefs.bool(CrustyService.this, Prefs.LOG_KERNEL, true)) {
                sh("dmesg > " + new File(sBootDir, "kernel.txt").getPath() + " 2>&1");
            }
            mWorker.postDelayed(this, 30000);
        }
    };

    private final Runnable mPeriodicSnapshot = new Runnable() {
        public void run() {
            if (Prefs.bool(CrustyService.this, Prefs.LOG_SNAPSHOTS, true)) snapshot("periodic");
            mWorker.postDelayed(this, 5 * 60 * 1000);
        }
    };

    // state dump for debugging offline: focus, keyguard, recents, input devices, tasks and whatever else dumpsys yaps about
    void snapshot(String why) {
        String name = new SimpleDateFormat("HHmmss", Locale.US).format(new Date()) + "-" + why.replaceAll("[^A-Za-z0-9+_-]", "_");
        File f = new File(new File(sBootDir, "snapshots"), name + ".txt");
        event("snapshot " + f.getName());
        String[] cmds = {
                "date; cat /proc/uptime",
                "dumpsys window policy",
                "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp|Window #'",
                "dumpsys activity activities",
                "dumpsys package preferred",
                "dumpsys input",
                "dumpsys power",
                "dumpsys statusbar",
                "ls -l " + LED_DIR + "/; for a in " + LED_DIR + "/*; do [ -f $a ] && echo \"$a = $(cat $a 2>&1)\"; done",
                "getprop",
        };
        for (String c : cmds) {
            write(f, "\n===== " + c + "\n", true);
            sh(c + " >> " + f.getPath() + " 2>&1");
        }
    }

    // ------------------------------------------------------------------ LEDs

    private final Runnable mLedPoll = new Runnable() {
        public void run() {
            pollLeds();
            mWorker.postDelayed(this, 2000);
        }
    };

    private void pollLeds() {
        pollAttrs(BL_DIR, "backlight ", null);
        File[] attrs = LED_DIR.listFiles();
        if (attrs == null) { sLedState = "no " + LED_DIR; return; }
        StringBuilder sb = pollAttrs(LED_DIR, "led ", attrs);
        sLedState = sb.toString().trim();
        String b = mLastLed.get("led brightness");
        String st = mLastLed.get("led status");
        boolean off = "0".equals(b) || (st != null && st.contains("real_status=OFF"));
        LedController led = LedController.get(this);
        // 3 s of grace after our own writes so we dont fight ourselves
        if (off && !mLedWasOff && led.desiredLevel() > 0
                && SystemClock.elapsedRealtime() - Blanker.sLastOwnWrite > 3000) {
            event("leds went dark behind our back -> re-apply");
            led.apply(true);
        }
        mLedWasOff = off;
    }

    private StringBuilder pollAttrs(File dir, String prefix, File[] attrs) {
        if (attrs == null) attrs = dir.listFiles();
        StringBuilder sb = new StringBuilder();
        if (attrs == null) return sb;
        for (File a : attrs) {
            if (!a.isFile() || !a.canRead()) continue;
            String v = read(a);
            if (v == null) continue;
            v = v.trim();
            if (v.length() > 200) continue;
            sb.append(a.getName()).append('=').append(v).append(' ');
            String old = mLastLed.put(prefix + a.getName(), v);
            if (old != null && !old.equals(v)) {
                event(prefix + a.getName() + ": " + old + " -> " + v + " (screen " + (mInteractive ? "on" : "off")
                        + (Blanker.blanked() ? ", blanked" : "") + ")");
            }
        }
        return sb;
    }

    private boolean mLedWasOff;

    // ------------------------------------------------------------------ utils

    static void sh(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[] { "sh", "-c", cmd });
            p.getOutputStream().close();
            p.waitFor();
        } catch (Exception e) {
            Log.w(TAG, "sh failed: " + cmd, e);
        }
    }

    static String read(File f) {
        try {
            BufferedReader r = new BufferedReader(new FileReader(f));
            try {
                StringBuilder sb = new StringBuilder();
                char[] buf = new char[4096];
                int n;
                while ((n = r.read(buf)) > 0) sb.append(buf, 0, n);
                return sb.toString();
            } finally {
                r.close();
            }
        } catch (IOException e) {
            return null;
        }
    }

    static boolean write(File f, String s, boolean append) {
        try {
            FileWriter w = new FileWriter(f, append);
            try { w.write(s); } finally { w.close(); }
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    static void rmrf(File f) {
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) rmrf(k);
        f.delete();
    }
}
