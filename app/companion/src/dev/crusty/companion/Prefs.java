package dev.crusty.companion;

import android.content.Context;
import android.content.SharedPreferences;
import android.preference.PreferenceManager;
import android.util.Base64;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashSet;
import java.util.Set;

// every crusty setting lives here (default SharedPreferences), plus a few small helpers
final class Prefs {
    private Prefs() { }

    // ---- side buttons, power is fixed (short = screen off/on, long = crusty app) so it doesnt show up here
    static final String[] BUTTONS = { "home", "lamp", "up", "down" };
    static final String[] BUTTON_LABELS = { "Home", "Lamp", "Up", "Down" };
    static final String[][] BUTTON_DEFAULTS = {          // short, long
            { "home", "recents" },
            { "recents", "notifications" },
            { "volume_up", "brightness_up" },
            { "volume_down", "brightness_down" },
    };

    // ---- actions
    static final String[] ACTIONS = {
            "none", "home", "back", "recents", "notifications", "quick_settings",
            "volume_up", "volume_down", "mute", "brightness_up", "brightness_down",
            "screen_off", "leds_toggle", "app", "crusty",
    };
    static final String[] ACTION_LABELS = {
            "nothing", "home", "back", "recent apps", "notifications", "quick settings",
            "volume up", "volume down", "mute / unmute", "brightness up", "brightness down",
            "screen off", "button leds on/off", "launch app...", "open crusty",
    };
    // profile value for "use the default mapping"
    static final String INHERIT = "inherit";

    static String buttonKey(String button, boolean longPress) {
        return "btn." + button + (longPress ? ".long" : ".short");
    }

    static String buttonAppKey(String button, boolean longPress) {
        return buttonKey(button, longPress) + ".app";
    }

    static String profileKey(String pkg, String button, boolean longPress) {
        return "profile." + pkg + "." + button + (longPress ? ".long" : ".short");
    }

    static String profileAppKey(String pkg, String button, boolean longPress) {
        return profileKey(pkg, button, longPress) + ".app";
    }

    static final String PROFILES = "profiles";           // string set of package names

    // ---- LEDs / screen
    static final String LED_LEVEL = "led.level";          // 1..255
    static final String LED_AWAKE = "led.awake";          // on | touch | off
    static final String LED_TOUCH_SECONDS = "led.touch_seconds";
    static final String LED_SLEEP = "led.sleep";          // off | dim | on
    static final String LED_SLEEP_LEVEL = "led.sleep_level";
    static final String IDLE_MINUTES = "screen.idle_minutes"; // 0 = never

    // ---- android tweaks
    static final String HIDE_STATUSBAR = "tweak.hide_statusbar";
    static final String NAVBAR = "tweak.navbar";
    static final String ROTATION = "tweak.rotation";      // auto | 0 | 1 | 2 | 3
    static final String DENSITY = "tweak.density";        // "" = default
    static final String ANIM_SCALE = "tweak.anim_scale";  // "" = leave alone, "0", "0.5", "1"
    static final String SHOW_TOUCHES = "tweak.show_touches";

    // ---- kiosk
    static final String KIOSK = "kiosk.enabled";
    static final String KIOSK_PKG = "kiosk.package";
    static final String KIOSK_HIDE_BARS = "kiosk.hide_bars";
    static final String AUTOSTART_PKG = "autostart.package";

    // ---- logging
    static final String LOG_LOGCAT = "log.logcat";
    static final String LOG_KERNEL = "log.kernel";
    static final String LOG_SNAPSHOTS = "log.snapshots";

    // ---- time
    static final String TIME_SYNC = "time.sync";          // NTP on/off (default on)
    static final String TIME_SERVER = "time.server";      // default pool.ntp.org

    // ---- PIN
    static final String PIN_HASH = "pin.hash";

    static SharedPreferences get(Context c) {
        return PreferenceManager.getDefaultSharedPreferences(c.getApplicationContext());
    }

    static String str(Context c, String key, String def) {
        try {
            return get(c).getString(key, def);
        } catch (ClassCastException e) {
            return def;
        }
    }

    static int num(Context c, String key, int def) {
        try {
            return Integer.parseInt(str(c, key, String.valueOf(def)).trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    static boolean bool(Context c, String key, boolean def) {
        try {
            return get(c).getBoolean(key, def);
        } catch (ClassCastException e) {
            return def;
        }
    }

    static Set<String> profiles(Context c) {
        return new HashSet<String>(get(c).getStringSet(PROFILES, new HashSet<String>()));
    }

    static String defaultAction(int buttonIndex, boolean longPress) {
        return BUTTON_DEFAULTS[buttonIndex][longPress ? 1 : 0];
    }

    static String actionLabel(String action) {
        for (int i = 0; i < ACTIONS.length; i++) if (ACTIONS[i].equals(action)) return ACTION_LABELS[i];
        return INHERIT.equals(action) ? "(default)" : action;
    }

    // ---- PIN (salted SHA-256, stored as "salt:hash")
    static boolean hasPin(Context c) {
        return str(c, PIN_HASH, "").length() > 0;
    }

    static void setPin(Context c, String pin) {
        if (pin == null || pin.length() == 0) {
            get(c).edit().remove(PIN_HASH).apply();
            return;
        }
        byte[] salt = new byte[16];
        new SecureRandom().nextBytes(salt);
        String s = Base64.encodeToString(salt, Base64.NO_WRAP);
        get(c).edit().putString(PIN_HASH, s + ":" + hash(s, pin)).apply();
    }

    static boolean checkPin(Context c, String pin) {
        String stored = str(c, PIN_HASH, "");
        int i = stored.indexOf(':');
        if (i < 0) return true;   // no PIN stored = everybody gets in
        return MessageDigest.isEqual(stored.substring(i + 1).getBytes(), hash(stored.substring(0, i), pin).getBytes());
    }

    private static String hash(String salt, String pin) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            md.update(salt.getBytes("UTF-8"));
            md.update(pin.getBytes("UTF-8"));
            return Base64.encodeToString(md.digest(), Base64.NO_WRAP);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
