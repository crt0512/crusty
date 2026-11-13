package dev.crusty.companion;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;

// the "hidden" android settings, applied idempotently: on boot, on change, and again whenever something else stomps on them (crestrons platform service loves switching animations off at boot for example)
final class Tweaks {
    private Tweaks() { }

    static final String SETTING_NAVBAR = "crusty_navbar";             // read by our SystemUI patch
    static final String ACTION_RESTART_SYSTEMUI = "dev.crusty.RESTART_SYSTEMUI";

    static void applyAll(Context c) {
        applyBars(c);
        applyRotation(c);
        applyDensity(c);
        applyAnimations(c);
        putSystemInt(c, "show_touches", Prefs.bool(c, Prefs.SHOW_TOUCHES, false) ? 1 : 0);
    }

    // status bar goes immersive via policy_control, the nav bar is our SystemUI patch and only changes when SystemUI restarts
    static void applyBars(Context c) {
        boolean kioskHide = Kiosk.active(c) && Prefs.bool(c, Prefs.KIOSK_HIDE_BARS, true);
        ContentResolver cr = c.getContentResolver();

        boolean hideStatus = kioskHide || Prefs.bool(c, Prefs.HIDE_STATUSBAR, false);
        String policy = hideStatus ? "immersive.status=*:immersive.preconfirms=*" : null;
        String cur = Settings.Global.getString(cr, "policy_control");
        if (!eq(cur, policy)) {
            Settings.Global.putString(cr, "policy_control", policy);
            CrustyService.event("tweak: policy_control " + cur + " -> " + policy);
        }

        int nav = (Prefs.bool(c, Prefs.NAVBAR, true) && !kioskHide) ? 1 : 0;
        int curNav = Settings.Global.getInt(cr, SETTING_NAVBAR, 1);
        if (curNav != nav) {
            Settings.Global.putInt(cr, SETTING_NAVBAR, nav);
            CrustyService.event("tweak: nav bar " + curNav + " -> " + nav + ", restarting SystemUI");
            c.sendBroadcast(new Intent(ACTION_RESTART_SYSTEMUI));
        }
    }

    static void applyRotation(Context c) {
        String r = Prefs.str(c, Prefs.ROTATION, "keep");
        if ("keep".equals(r)) return;
        if ("auto".equals(r)) {
            putSystemInt(c, Settings.System.ACCELEROMETER_ROTATION, 1);
        } else {
            putSystemInt(c, Settings.System.ACCELEROMETER_ROTATION, 0);
            putSystemInt(c, Settings.System.USER_ROTATION, Integer.parseInt(r));
        }
    }

    static void applyDensity(Context c) {
        String want = Prefs.str(c, Prefs.DENSITY, "");
        String applied = Prefs.str(c, Prefs.DENSITY + ".applied", "");
        // we remember what we applied, running wm density on every applyAll would be stoopid
        if (want.equals(applied)) return;
        CrustyService.sh("wm density " + (want.length() == 0 ? "reset" : want));
        Prefs.get(c).edit().putString(Prefs.DENSITY + ".applied", want).apply();
        CrustyService.event("tweak: density -> " + (want.length() == 0 ? "default" : want));
    }

    static void applyAnimations(Context c) {
        String s = Prefs.str(c, Prefs.ANIM_SCALE, "");
        if (s.length() == 0) return;
        float f = Float.parseFloat(s);
        ContentResolver cr = c.getContentResolver();
        for (String k : new String[] { "window_animation_scale", "transition_animation_scale", "animator_duration_scale" }) {
            if (Settings.Global.getFloat(cr, k, 1f) != f) {
                Settings.Global.putFloat(cr, k, f);
                CrustyService.event("tweak: " + k + " -> " + f);
            }
        }
    }

    private static void putSystemInt(Context c, String k, int v) {
        if (Settings.System.getInt(c.getContentResolver(), k, -1) != v) {
            Settings.System.putInt(c.getContentResolver(), k, v);
        }
    }

    private static boolean eq(String a, String b) {
        if (a == null || a.length() == 0) return b == null || b.length() == 0;
        return a.equals(b);
    }
}
