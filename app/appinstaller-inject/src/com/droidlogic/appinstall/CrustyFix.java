package com.droidlogic.appinstall;

import java.lang.reflect.Field;

// gets injected into amlogics AppInstaller by tools/patches.py
// main.showChooseDev() builds mDevStrs (labels) for mDevs (paths) but only knows labels for amlogics usual mount points, not the panels (/storage/udisk0, ...)
// the null labels then crash the device chooser (ArrayAdapter -> null.toString()), so we fall back to the path
public final class CrustyFix {
    private CrustyFix() { }

    public static void fixDevStrs(Object main) {
        try {
            Field fs = main.getClass().getDeclaredField("mDevStrs");
            Field fd = main.getClass().getDeclaredField("mDevs");
            fs.setAccessible(true);
            fd.setAccessible(true);
            String[] strs = (String[]) fs.get(main);
            String[] devs = (String[]) fd.get(main);
            if (strs == null) return;
            for (int i = 0; i < strs.length; i++) {
                if (strs[i] == null) {
                    strs[i] = devs != null && i < devs.length && devs[i] != null ? devs[i] : "?";
                }
            }
        } catch (Exception e) {
            android.util.Log.w("crusty", "AppInstaller fixDevStrs failed", e);
        }
    }
}
