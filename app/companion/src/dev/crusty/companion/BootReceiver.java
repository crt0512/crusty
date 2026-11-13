package dev.crusty.companion;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// starts the crusty service at boot, android only bothers telling us about the boot after the app has been opened once though
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        context.startService(new Intent(context, CrustyService.class));
    }
}
