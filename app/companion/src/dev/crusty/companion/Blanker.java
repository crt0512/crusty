package dev.crusty.companion;

import android.content.Context;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

import java.io.File;

// fake "screen off": backlight to 0 plus a black fullscreen overlay that eats the first touch and wakes the screen up again
// android itself never goes to sleep here, its real screen-off runs the kernel early-suspend which holds the ft5x06 touch controller in reset and then nothing can wake the panel anymore (the side buttons hang off that same controller so they die with it)
// what the leds do while blanked is LedController's business (its sleep mode)
final class Blanker {
    static final File BACKLIGHT = new File("/sys/class/backlight/aml-bl/brightness");
    static final File KPLED = new File("/sys/class/keypad_led/brightness");

    private static Blanker sInstance;
    // elapsedRealtime of our own last backlight/led write, so the poller in CrustyService can tell our writes from somebody else messing with the leds
    static volatile long sLastOwnWrite;

    static boolean writeBacklight(String v) {
        sLastOwnWrite = SystemClock.elapsedRealtime();
        return CrustyService.write(BACKLIGHT, v + "\n", false);
    }

    static boolean writeLed(String v) {
        sLastOwnWrite = SystemClock.elapsedRealtime();
        return CrustyService.write(KPLED, v + "\n", false);
    }

    private final Context mContext;
    private final WindowManager mWm;
    private View mOverlay;

    static synchronized Blanker get(Context c) {
        if (sInstance == null) sInstance = new Blanker(c.getApplicationContext());
        return sInstance;
    }

    static boolean blanked() {
        return sInstance != null && sInstance.isBlanked();
    }

    private Blanker(Context c) {
        mContext = c;
        mWm = (WindowManager) c.getSystemService(Context.WINDOW_SERVICE);
    }

    boolean isBlanked() {
        return mOverlay != null;
    }

    void blank(String why) {
        if (mOverlay != null) return;
        View v = new View(mContext);
        v.setBackgroundColor(Color.BLACK);
        v.setOnTouchListener(new View.OnTouchListener() {
            public boolean onTouch(View view, MotionEvent ev) {
                if (ev.getActionMasked() == MotionEvent.ACTION_DOWN) unblank("touch");
                return true;
            }
        });
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_FULLSCREEN,
                PixelFormat.OPAQUE);
        lp.setTitle("crusty-blank");
        try {
            mWm.addView(v, lp);
            mOverlay = v;
        } catch (Exception e) {
            CrustyService.event("blank: overlay failed: " + e);
        }
        boolean ok = writeBacklight("0");
        LedController.get(mContext).apply(false);
        CrustyService.event("blank (" + why + "): backlight -> 0 " + (ok ? "ok" : "FAILED"));
    }

    void unblank(String why) {
        if (mOverlay == null) return;
        try { mWm.removeView(mOverlay); } catch (Exception e) { }
        mOverlay = null;
        // back to what android thinks the brightness is, crestron may have forced the panel to 255 in the meantime
        int want = Settings.System.getInt(mContext.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128);
        writeBacklight(String.valueOf(Math.max(10, want)));
        LedController led = LedController.get(mContext);
        led.onUserActivity();
        led.apply(false);
        CrustyService.event("unblank (" + why + "): backlight -> " + want);
    }
}
