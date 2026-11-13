package com.android.systemui.crusty;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.provider.Settings;
import android.util.Log;

// gets injected into the panels SystemUI by tools/patches.py
// goHome(): the panels PhoneWindowManager (on the read only eMMC) sets mKeyguardDelegate = null in systemReady(), so every KEYCODE_HOME crashes in launchHomeFromHotKey() with a NullPointerException and does nothing (premium engineering), thats why the nav bar Home button starts the home activity itself
// showNavBar(): PhoneStatusBar asks us instead of IWindowManager.hasNavigationBar(), which says false because of qemu.hw.mainkeys=1
// the answer comes from Settings.Global "crusty_navbar" (default on) which the crusty companion flips, it then broadcasts RESTART so SystemUI rebuilds its bars
public final class CrustyHome {
    public static final String SETTING_NAVBAR = "crusty_navbar";
    public static final String ACTION_RESTART = "dev.crusty.RESTART_SYSTEMUI";
    private static boolean sReceiverRegistered;

    private CrustyHome() { }

    public static void goHome(Context c) {
        try {
            c.sendBroadcast(new Intent(Intent.ACTION_CLOSE_SYSTEM_DIALOGS).putExtra("reason", "homekey"));
            c.startActivity(new Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED));
        } catch (Exception e) {
            Log.w("crusty", "goHome failed", e);
        }
    }

    public static boolean showNavBar(Context c) {
        registerRestart(c);
        try {
            return Settings.Global.getInt(c.getContentResolver(), SETTING_NAVBAR, 1) != 0;
        } catch (Exception e) {
            return true;
        }
    }

    // SystemUI is a persistent app, if it exits ActivityManager restarts it right away, so killing ourselves IS the restart
    private static synchronized void registerRestart(Context c) {
        if (sReceiverRegistered) return;
        sReceiverRegistered = true;
        try {
            // only senders holding STATUS_BAR (signature|system, the crusty companion for example) get to restart us, otherwise any random app could kill SystemUI for fun
            c.getApplicationContext().registerReceiver(new BroadcastReceiver() {
                @Override
                public void onReceive(Context ctx, Intent i) {
                    Log.i("crusty", "SystemUI restart requested");
                    android.os.Process.killProcess(android.os.Process.myPid());
                }
            }, new IntentFilter(ACTION_RESTART), "android.permission.STATUS_BAR", null);
        } catch (Exception e) {
            Log.w("crusty", "registerRestart failed", e);
        }
    }
}
