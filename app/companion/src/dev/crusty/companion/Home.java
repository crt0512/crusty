package dev.crusty.companion;

import android.content.Context;
import android.content.Intent;

// what PhoneWindowManager.launchHomeFromHotKey() would do, minus the crash
final class Home {
    private Home() { }

    static void go(Context c) {
        try {
            c.sendBroadcast(new Intent(Intent.ACTION_CLOSE_SYSTEM_DIALOGS).putExtra("reason", "homekey"));
            c.startActivity(new Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED));
        } catch (Exception e) {
            CrustyService.event("home failed: " + e);
        }
    }
}
