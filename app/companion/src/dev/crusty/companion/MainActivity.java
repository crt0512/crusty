package dev.crusty.companion;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.widget.EditText;
import android.widget.Toast;

// the crusty settings screen, hosts SettingsFragment (the root screen, or one app profile via EXTRA_PROFILE)
// the optional PIN guards it: once unlocked it stays unlocked until no crusty screen is visible anymore
public class MainActivity extends Activity {
    static final String EXTRA_PROFILE = "profile";
    private static boolean sUnlocked;
    private static int sVisible;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        startService(new Intent(this, CrustyService.class));
        String profile = getIntent().getStringExtra(EXTRA_PROFILE);
        setTitle(profile == null ? "crusty" : "crusty - profile");
        if (b == null) {
            getFragmentManager().beginTransaction()
                    .replace(android.R.id.content, SettingsFragment.create(profile))
                    .commit();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        sVisible++;
        if (!sUnlocked && Prefs.hasPin(this)) askPin();
        else sUnlocked = true;
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (--sVisible <= 0 && !isChangingConfigurations()) {
            sVisible = 0;
            sUnlocked = false;   // lock again once crusty is left
        }
    }

    private void askPin() {
        final EditText pin = new EditText(this);
        pin.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        pin.setHint("PIN");
        new AlertDialog.Builder(this)
                .setTitle("crusty is locked")
                .setView(pin)
                .setCancelable(false)
                .setPositiveButton("unlock", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        if (Prefs.checkPin(MainActivity.this, pin.getText().toString())) {
                            sUnlocked = true;
                            CrustyService.event("crusty unlocked");
                        } else {
                            CrustyService.event("crusty: wrong PIN");
                            Toast.makeText(MainActivity.this, "wrong PIN, nice try", Toast.LENGTH_SHORT).show();
                            leave();
                        }
                    }
                })
                .setNegativeButton("cancel", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) { leave(); }
                })
                .show();
    }

    private void leave() {
        finish();
        if (Kiosk.active(this)) Kiosk.bringToFront(this);
    }
}
