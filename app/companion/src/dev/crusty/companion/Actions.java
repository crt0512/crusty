package dev.crusty.companion;

import android.accessibilityservice.AccessibilityService;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.provider.Settings;

// does whatever a button press is supposed to do, the action ids live in Prefs.ACTIONS
// in kiosk mode home means the kiosk app and recents/shade do nothing, otherwise you'd walk right out of it
final class Actions {
    private Actions() { }

    private static boolean sMuted;

    static void run(AccessibilityService svc, String action, String appPkg) {
        if (action == null || "none".equals(action) || Prefs.INHERIT.equals(action)) return;
        CrustyService.event("action " + action + ("app".equals(action) ? " " + appPkg : ""));
        AudioManager am = (AudioManager) svc.getSystemService(Context.AUDIO_SERVICE);
        if ("home".equals(action)) {
            if (Kiosk.active(svc)) Kiosk.bringToFront(svc); else Home.go(svc);
        } else if ("back".equals(action)) {
            svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK);
        } else if ("recents".equals(action)) {
            if (!Kiosk.active(svc)) svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS);
        } else if ("notifications".equals(action)) {
            if (!Kiosk.active(svc)) svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS);
        } else if ("quick_settings".equals(action)) {
            if (!Kiosk.active(svc)) svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS);
        } else if ("volume_up".equals(action)) {
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI);
        } else if ("volume_down".equals(action)) {
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI);
        } else if ("mute".equals(action)) {
            sMuted = !sMuted;
            am.setStreamMute(AudioManager.STREAM_MUSIC, sMuted);
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_SAME, AudioManager.FLAG_SHOW_UI);
        } else if ("brightness_up".equals(action) || "brightness_down".equals(action)) {
            int cur = Settings.System.getInt(svc.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128);
            int next = Math.max(10, Math.min(255, cur + ("brightness_up".equals(action) ? 25 : -25)));
            Settings.System.putInt(svc.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS_MODE,
                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL);
            Settings.System.putInt(svc.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, next);
        } else if ("screen_off".equals(action)) {
            Blanker.get(svc).blank("button action");
        } else if ("leds_toggle".equals(action)) {
            LedController.get(svc).toggleManualOff();
        } else if ("app".equals(action)) {
            launch(svc, appPkg);
        } else if ("crusty".equals(action)) {
            svc.startActivity(new Intent(svc, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP));
        }
    }

    static boolean launch(Context c, String pkg) {
        if (pkg == null || pkg.length() == 0) return false;
        Intent i = c.getPackageManager().getLaunchIntentForPackage(pkg);
        if (i == null) {
            CrustyService.event("launch: nothing to launch in " + pkg);
            return false;
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            c.startActivity(i);
            return true;
        } catch (Exception e) {
            CrustyService.event("launch " + pkg + " failed: " + e);
            return false;
        }
    }
}
