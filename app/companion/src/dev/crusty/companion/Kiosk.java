package dev.crusty.companion;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.lang.reflect.Method;

// kiosk mode: keeps one app in front, built from what a platform signed app can do on lollipop without being device owner
// StatusBarManager.disable() takes away the notification shade and Home/Recents in the nav bar, the bars themselves can be hidden on top of that (Tweaks: immersive status bar + nav bar off)
// the accessibility service reports every foreground change and anything that isnt the kiosk app gets the kiosk app thrown right back in front of it
// side buttons only do things that keep you in the app (home = kiosk app, recents/shade ignored)
// the way out: long press power -> crusty (PIN) -> "leave kiosk"
final class Kiosk {
    private Kiosk() { }

    // flags of android.app.StatusBarManager, hidden api so we bring our own copy
    static final int DISABLE_EXPAND = 0x00010000;
    static final int DISABLE_NOTIFICATION_ICONS = 0x00020000;
    static final int DISABLE_NOTIFICATION_ALERTS = 0x00040000;
    static final int DISABLE_HOME = 0x00200000;
    static final int DISABLE_RECENT = 0x01000000;
    static final int DISABLE_SEARCH = 0x02000000;

    private static Object sStatusBar; // hoard the instance, its binder token holds our disable flags and dropping it = flags go bye bye
    private static final Handler sHandler = new Handler(Looper.getMainLooper());
    private static long sLastRelaunch;

    static boolean active(Context c) {
        return Prefs.bool(c, Prefs.KIOSK, false) && pkg(c).length() > 0;
    }

    static String pkg(Context c) {
        return Prefs.str(c, Prefs.KIOSK_PKG, "");
    }

    static void start(Context c, String pkg) {
        Prefs.get(c).edit().putString(Prefs.KIOSK_PKG, pkg).putBoolean(Prefs.KIOSK, true).commit();
        CrustyService.event("kiosk: start " + pkg);
        apply(c);
        bringToFront(c);
    }

    static void stop(Context c) {
        Prefs.get(c).edit().putBoolean(Prefs.KIOSK, false).commit();
        CrustyService.event("kiosk: stop");
        apply(c);
    }

    static void apply(Context c) {
        boolean on = active(c);
        disableStatusBar(c, on ? DISABLE_EXPAND | DISABLE_NOTIFICATION_ICONS | DISABLE_NOTIFICATION_ALERTS
                | DISABLE_HOME | DISABLE_RECENT | DISABLE_SEARCH : 0);
        Tweaks.applyBars(c);
    }

    static void bringToFront(Context c) {
        if (!active(c)) return;
        sLastRelaunch = SystemClock.elapsedRealtime();
        Actions.launch(c, pkg(c));
    }

    static void onForeground(final Context c, String fgPkg) {
        if (!active(c) || fgPkg == null) return;
        if (allowed(c, fgPkg)) return;
        // debounce, transitions and our own launch need a moment before the foreground app means anything
        sHandler.removeCallbacksAndMessages(null);
        sHandler.postDelayed(new Runnable() {
            public void run() {
                String now = ButtonService.foreground();
                if (active(c) && (now == null || !allowed(c, now))
                        && SystemClock.elapsedRealtime() - sLastRelaunch > 1500) {
                    CrustyService.event("kiosk: " + now + " in foreground -> back to " + pkg(c));
                    bringToFront(c);
                }
            }
        }, 700);
    }

    private static boolean allowed(Context c, String p) {
        return p.equals(pkg(c))
                || p.equals(c.getPackageName())      // crusty itself, otherwise nobody gets to the PIN screen to leave
                || p.equals("com.android.systemui")  // volume panel etc.
                || p.equals("android");              // system dialogs (ANR, ...)
    }

    static void disableStatusBar(Context c, int flags) {
        try {
            if (sStatusBar == null) sStatusBar = c.getApplicationContext().getSystemService("statusbar");
            Method m = sStatusBar.getClass().getMethod("disable", int.class);
            m.invoke(sStatusBar, flags);
        } catch (Exception e) {
            CrustyService.event("kiosk: statusbar.disable said no: " + e);
        }
    }
}
