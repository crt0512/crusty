package dev.crusty.companion;

import android.accessibilityservice.AccessibilityService;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.PixelFormat;
import android.os.Handler;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;

// side buttons, plus keeping track of which app is in front (app profiles, kiosk) and whether anybody touched the panel lately
// its a key filtering accessibility service because that is the one thing that sees hardware keys *before* PhoneWindowManager.interceptKeyBeforeDispatching
// the buttons arrive as BUTTON_1..5 (config/input/buttons.kl) and only mean what crusty says they mean
// KEYCODE_HOME (ir remote for example) would crash in the panels PhoneWindowManager so it gets handled here
// there is no POWER keycode at all on purpose, androids screen-off locks the touch controller (see Blanker)
// power (BUTTON_1) is fixed: short = screen off/on, long = crusty app, the other four are configurable and even per app if the app in front has a profile
public class ButtonService extends AccessibilityService implements SharedPreferences.OnSharedPreferenceChangeListener {
    static final int[] KEYS = {
            KeyEvent.KEYCODE_BUTTON_1,  // power
            KeyEvent.KEYCODE_BUTTON_2,  // home
            KeyEvent.KEYCODE_BUTTON_3,  // lamp
            KeyEvent.KEYCODE_BUTTON_4,  // up
            KeyEvent.KEYCODE_BUTTON_5,  // down
    };
    static final long LONG_PRESS_MS = 700;

    private static volatile String sForeground;

    static String foreground() { return sForeground; }

    private final Handler mHandler = new Handler();
    private Blanker mBlanker;
    private View mTouchWatcher;
    private int mDownButton = -1;      // index into KEYS of the button being held, -1 = none
    private boolean mLongFired;
    private int mSwallowUpOf = -1;

    private final Runnable mLongPress = new Runnable() {
        public void run() {
            if (mDownButton < 0) return;
            mLongFired = true;
            press(mDownButton, true);
        }
    };

    private final Runnable mIdle = new Runnable() {
        public void run() {
            if (!mBlanker.isBlanked()) mBlanker.blank("idle " + Prefs.num(ButtonService.this, Prefs.IDLE_MINUTES, 0) + " min");
        }
    };

    @Override
    protected void onServiceConnected() {
        mBlanker = Blanker.get(this);
        startService(new Intent(this, CrustyService.class));
        Prefs.get(this).registerOnSharedPreferenceChangeListener(this);
        addTouchWatcher();
        Kiosk.apply(this);
        userActivity();
        CrustyService.event("button service connected");
    }

    @Override
    public void onDestroy() {
        Prefs.get(this).unregisterOnSharedPreferenceChangeListener(this);
        if (mTouchWatcher != null) {
            try { ((WindowManager) getSystemService(WINDOW_SERVICE)).removeView(mTouchWatcher); } catch (Exception e) { }
        }
        super.onDestroy();
    }

    @Override
    public void onSharedPreferenceChanged(SharedPreferences sp, String key) {
        if (key == null) return;
        if (key.startsWith("led.")) LedController.get(this).apply(false);
        if (key.equals(Prefs.IDLE_MINUTES)) userActivity();
    }

    // ------------------------------------------------------------------ keys

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        int code = e.getKeyCode();
        boolean down = e.getAction() == KeyEvent.ACTION_DOWN;
        boolean first = down && e.getRepeatCount() == 0;
        int idx = indexOf(code);
        if (idx >= 0 || code == KeyEvent.KEYCODE_HOME) userActivity();

        // screen blanked: the first press of any button only wakes it and and nothing else, its key up gets swallowed too
        if (mBlanker != null && mBlanker.isBlanked() && (idx >= 0 || code == KeyEvent.KEYCODE_HOME)) {
            if (first) {
                CrustyService.event("button " + KeyEvent.keyCodeToString(code) + " -> unblank");
                mBlanker.unblank("button");
                mSwallowUpOf = code;
            }
            return true;
        }
        if (!down && code == mSwallowUpOf) {
            mSwallowUpOf = -1;
            return true;
        }

        if (code == KeyEvent.KEYCODE_HOME) {   // ir remote for example, would crash in PhoneWindowManager
            if (!down && !e.isCanceled()) Actions.run(this, "home", null);
            return true;
        }
        if (idx < 0) return false;

        if (first) {
            mDownButton = idx;
            mLongFired = false;
            mHandler.removeCallbacks(mLongPress);
            mHandler.postDelayed(mLongPress, LONG_PRESS_MS);
        } else if (!down && idx == mDownButton) {
            mHandler.removeCallbacks(mLongPress);
            if (!mLongFired && !e.isCanceled()) press(idx, false);
            mDownButton = -1;
        }
        return true;
    }

    private void press(int idx, boolean longPress) {
        if (idx == 0) { // power: fixed
            if (longPress) {
                CrustyService.event("button power long -> crusty");
                Actions.run(this, "crusty", null);
            } else {
                CrustyService.event("button power -> screen off");
                mBlanker.blank("power button");
            }
            return;
        }
        String button = Prefs.BUTTONS[idx - 1];
        String[] a = resolve(idx - 1, longPress);
        CrustyService.event("button " + button + (longPress ? " long" : "") + " -> " + a[0]
                + (sForeground != null ? " (fg " + sForeground + ")" : ""));
        Actions.run(this, a[0], a[1]);
    }

    // {action, appPackage} for a button, the profile of the app in front wins over the default mapping
    String[] resolve(int b, boolean longPress) {
        String button = Prefs.BUTTONS[b];
        String fg = sForeground;
        if (fg != null && Prefs.profiles(this).contains(fg)) {
            String act = Prefs.str(this, Prefs.profileKey(fg, button, longPress), Prefs.INHERIT);
            if (!Prefs.INHERIT.equals(act)) {
                return new String[] { act, Prefs.str(this, Prefs.profileAppKey(fg, button, longPress), "") };
            }
        }
        return new String[] {
                Prefs.str(this, Prefs.buttonKey(button, longPress), Prefs.defaultAction(b, longPress)),
                Prefs.str(this, Prefs.buttonAppKey(button, longPress), ""),
        };
    }

    private static int indexOf(int code) {
        for (int i = 0; i < KEYS.length; i++) if (KEYS[i] == code) return i;
        return -1;
    }

    // ------------------------------------------------------------------ foreground / activity

    @Override
    public void onAccessibilityEvent(AccessibilityEvent ev) {
        if (ev.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || ev.getPackageName() == null) return;
        String pkg = ev.getPackageName().toString();
        if (pkg.equals(sForeground)) return;
        // systemui popups (volume panel, shade) dont count as "the app in front" for profiles
        if (!pkg.equals("com.android.systemui")) sForeground = pkg;
        Kiosk.onForeground(this, pkg);
    }

    @Override
    public void onInterrupt() { }

    // 1x1 invisible window that gets ACTION_OUTSIDE for every touch anywhere without eating it, thats how we notice somebody is using the panel
    private void addTouchWatcher() {
        View v = new View(this);
        v.setOnTouchListener(new View.OnTouchListener() {
            public boolean onTouch(View view, MotionEvent ev) {
                userActivity();
                return false;
            }
        });
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(1, 1,
                WindowManager.LayoutParams.TYPE_SYSTEM_ALERT,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.LEFT | Gravity.TOP;
        lp.setTitle("crusty-touchwatch");
        try {
            ((WindowManager) getSystemService(WINDOW_SERVICE)).addView(v, lp);
            mTouchWatcher = v;
        } catch (Exception e) {
            CrustyService.event("touch watcher failed: " + e);
        }
    }

    private void userActivity() {
        LedController.get(this).onUserActivity();
        mHandler.removeCallbacks(mIdle);
        int min = Prefs.num(this, Prefs.IDLE_MINUTES, 0);
        if (min > 0) mHandler.postDelayed(mIdle, min * 60000L);
    }
}
