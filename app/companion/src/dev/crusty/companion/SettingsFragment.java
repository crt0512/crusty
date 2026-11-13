package dev.crusty.companion;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.os.PowerManager;
import android.preference.EditTextPreference;
import android.preference.ListPreference;
import android.preference.Preference;
import android.preference.PreferenceCategory;
import android.preference.PreferenceFragment;
import android.preference.PreferenceGroup;
import android.preference.PreferenceScreen;
import android.preference.SwitchPreference;
import android.text.InputType;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Set;

// all the crusty settings screens, built in code so there are no preference XMLs to drag through our gradle-less build
public class SettingsFragment extends PreferenceFragment {
    // crestron packages that must never be disabled, empty these days because platformd and txrx are gone
    static final Set<String> REQUIRED = new java.util.HashSet<String>();
    private String mProfile;   // null = root screen
    private String[] mAppLabels, mAppPkgs;

    static SettingsFragment create(String profile) {
        SettingsFragment f = new SettingsFragment();
        Bundle b = new Bundle();
        b.putString(MainActivity.EXTRA_PROFILE, profile);
        f.setArguments(b);
        return f;
    }

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        mProfile = getArguments() != null ? getArguments().getString(MainActivity.EXTRA_PROFILE) : null;
    }

    @Override
    public void onResume() {
        super.onResume();
        loadApps();
        setPreferenceScreen(mProfile == null ? buildRoot() : buildProfile(mProfile));
    }

    private Context ctx() { return getActivity(); }

    // =================================================================== root

    private PreferenceScreen buildRoot() {
        PreferenceScreen root = getPreferenceManager().createPreferenceScreen(ctx());

        Preference status = info(status(), null);
        root.addPreference(status);

        // ---- buttons
        PreferenceCategory btn = category(root, "side buttons");
        btn.addPreference(info("Power", "short press: screen off / on - long press: open crusty (hardwired, not up for debate)"));
        for (int i = 0; i < Prefs.BUTTONS.length; i++) {
            PreferenceScreen s = getPreferenceManager().createPreferenceScreen(ctx());
            s.setTitle(Prefs.BUTTON_LABELS[i]);
            s.setSummary(Prefs.actionLabel(Prefs.str(ctx(), Prefs.buttonKey(Prefs.BUTTONS[i], false), Prefs.defaultAction(i, false)))
                    + " - long: " + Prefs.actionLabel(Prefs.str(ctx(), Prefs.buttonKey(Prefs.BUTTONS[i], true), Prefs.defaultAction(i, true))));
            btn.addPreference(s);
            for (boolean lp : new boolean[] { false, true }) {
                actionPicker(s, (lp ? "long press" : "short press"),
                        Prefs.buttonKey(Prefs.BUTTONS[i], lp), Prefs.buttonAppKey(Prefs.BUTTONS[i], lp),
                        Prefs.defaultAction(i, lp), false);
            }
        }

        PreferenceScreen prof = getPreferenceManager().createPreferenceScreen(ctx());
        prof.setTitle("app profiles");
        prof.setSummary("different button actions while a certain app is in front");
        btn.addPreference(prof);
        final ListPreference add = appList("add profile for...", null, false);
        add.setPersistent(false);
        add.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                Set<String> set = Prefs.profiles(ctx());
                set.add((String) v);
                Prefs.get(ctx()).edit().putStringSet(Prefs.PROFILES, set).apply();
                openProfile((String) v);
                return false;
            }
        });
        prof.addPreference(add);
        for (final String pkg : sorted(Prefs.profiles(ctx()))) {
            Preference p = new Preference(ctx());
            p.setTitle(appLabel(pkg));
            p.setSummary(pkg);
            p.setOnPreferenceClickListener(new Preference.OnPreferenceClickListener() {
                public boolean onPreferenceClick(Preference x) { openProfile(pkg); return true; }
            });
            prof.addPreference(p);
        }

        // ---- LEDs + screen
        PreferenceCategory led = category(root, "button leds & screen");
        PreferenceScreen each = getPreferenceManager().createPreferenceScreen(ctx());
        each.setTitle("individual leds");
        boolean perLed = LedController.sOnoffFormat != null;
        each.setSummary(perLed ? "switch the led of each button on or off"
                : "not available: " + LedController.sOnoffInfo);
        each.setEnabled(perLed);
        led.addPreference(each);
        if (perLed) {
            each.addPreference(info("individual leds", "which leds are lit while the panel is awake and while "
                    + "the screen is off. how bright they are gets decided on the previous page."));
            for (int i = 5; i >= 1; i--) {             // top to bottom, like on the panel
                final int n = i;
                String name = LedController.LED_BUTTONS[n] + " button";
                PreferenceCategory c = category(each, name + " (led" + n + ")");
                c.addPreference(sw("lit when awake", LedController.ledKey(n), true, null));
                c.addPreference(sw("lit when the screen is off", LedController.ledSleepKey(n), true,
                        "only if \"when screen is off\" is dim or on"));
                c.addPreference(action("blink it", "blinks 4 times so you see which one it is", new Runnable() {
                    public void run() { LedController.get(ctx()).identify(n); }
                }));
            }
        }
        led.addPreference(list("when awake", Prefs.LED_AWAKE, "on",
                new String[] { "always on", "light up on touch", "off" }, new String[] { "on", "touch", "off" }));
        led.addPreference(number("brightness (1-255)", Prefs.LED_LEVEL, "128"));
        led.addPreference(number("light up on touch for (seconds)", Prefs.LED_TOUCH_SECONDS, "10"));
        led.addPreference(list("when screen is off", Prefs.LED_SLEEP, "off",
                new String[] { "off", "dim", "on" }, new String[] { "off", "dim", "on" }));
        led.addPreference(number("dim brightness (1-255)", Prefs.LED_SLEEP_LEVEL, "10"));
        led.addPreference(list("screen off when nobody touched it for", Prefs.IDLE_MINUTES, "0",
                new String[] { "never", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "1 h" },
                new String[] { "0", "1", "2", "5", "10", "15", "30", "60" }));

        // ---- android tweaks
        PreferenceCategory tw = category(root, "android settings");
        tw.addPreference(sw("hide status bar", Prefs.HIDE_STATUSBAR, false, "swipe down from the top to get it back"));
        tw.addPreference(sw("navigation bar", Prefs.NAVBAR, true, "soft back / home / recents (restarts SystemUI)"));
        tw.addPreference(list("rotation", Prefs.ROTATION, "keep",
                new String[] { "dont change", "auto", "0 deg", "90 deg", "180 deg", "270 deg" },
                new String[] { "keep", "auto", "0", "1", "2", "3" }));
        tw.addPreference(list("display density", Prefs.DENSITY, "",
                new String[] { "default", "120", "130", "140", "160", "190", "213", "240" },
                new String[] { "", "120", "130", "140", "160", "190", "213", "240" }));
        tw.addPreference(list("animations", Prefs.ANIM_SCALE, "",
                new String[] { "dont change", "off", "0.5x", "1x" }, new String[] { "", "0", "0.5", "1" }));
        tw.addPreference(sw("show touches", Prefs.SHOW_TOUCHES, false, null));
        tw.addPreference(action("open android settings", null, new Runnable() {
            public void run() { startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS)); }
        }));

        // ---- time
        PreferenceCategory tm = category(root, "date & time");
        tm.addPreference(sw("set the clock from the internet (NTP)", Prefs.TIME_SYNC, true,
                "without it the panels clock is stuck at crestrons build date -> SSL errors on every site"));
        final EditTextPreference ntp = new EditTextPreference(ctx());
        ntp.setKey(Prefs.TIME_SERVER);
        ntp.setTitle("NTP server");
        ntp.setDefaultValue("pool.ntp.org");
        ntp.setText(NtpSync.server(ctx()));
        ntp.setSummary(NtpSync.server(ctx()));
        ntp.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) { p.setSummary((String) v); return true; }
        });
        tm.addPreference(ntp);
        tm.addPreference(action("sync now", NtpSync.sLast, new Runnable() {
            public void run() {
                NtpSync.syncNow(ctx());
                Toast.makeText(ctx(), "syncing... (result shows up here after reopening)", Toast.LENGTH_SHORT).show();
            }
        }));
        tm.addPreference(action("time zone & format", "androids date & time settings", new Runnable() {
            public void run() { startActivity(new Intent(android.provider.Settings.ACTION_DATE_SETTINGS)); }
        }));

        // ---- kiosk
        PreferenceCategory k = category(root, "kiosk & autostart");
        k.addPreference(appList("start app at boot", Prefs.AUTOSTART_PKG, true));
        k.addPreference(appList("kiosk app", Prefs.KIOSK_PKG, false));
        k.addPreference(sw("hide status & nav bar in kiosk", Prefs.KIOSK_HIDE_BARS, true, null));
        final boolean on = Kiosk.active(ctx());
        k.addPreference(action(on ? "leave kiosk" : "start kiosk",
                on ? "kiosk running: " + appLabel(Kiosk.pkg(ctx()))
                   : "keeps the kiosk app in front. way out: hold Power -> crusty -> leave kiosk (set a PIN!)",
                new Runnable() {
                    public void run() {
                        if (on) {
                            Kiosk.stop(ctx());
                            setPreferenceScreen(buildRoot());
                        } else if (Kiosk.pkg(ctx()).length() == 0) {
                            Toast.makeText(ctx(), "pick a kiosk app first", Toast.LENGTH_SHORT).show();
                        } else {
                            if (!Prefs.hasPin(ctx())) {
                                Toast.makeText(ctx(), "tip: set a PIN otherwise anyone can just walk out of the kiosk", Toast.LENGTH_LONG).show();
                            }
                            Kiosk.start(ctx(), Kiosk.pkg(ctx()));
                        }
                    }
                }));

        // ---- crestron
        PreferenceScreen cr = getPreferenceManager().createPreferenceScreen(ctx());
        cr.setTitle("crestron apps");
        cr.setSummary("switch crestrons android apps and services on / off");
        root.addPreference(cr);
        cr.addPreference(info("careful", "background services (platform, txrx, ...) may be used by crestrons "
                + "daemons. if something breaks, switch it back on."));
        PackageManager pm = ctx().getPackageManager();
        List<ApplicationInfo> apps = pm.getInstalledApplications(PackageManager.GET_DISABLED_COMPONENTS);
        Collections.sort(apps, new Comparator<ApplicationInfo>() {
            public int compare(ApplicationInfo a, ApplicationInfo b) { return a.packageName.compareTo(b.packageName); }
        });
        for (final ApplicationInfo ai : apps) {
            String p = ai.packageName;
            if (!(p.startsWith("com.crestron.") || p.startsWith("air.air.") || p.startsWith("us.zoom."))) continue;
            final SwitchPreference s = new SwitchPreference(ctx());
            s.setPersistent(false);
            s.setTitle(String.valueOf(ai.loadLabel(pm)));
            s.setSummary(p);
            if (REQUIRED.contains(p)) {
                // disabling these made the panel hang at boot, crestrons stack depends on them
                s.setChecked(true);
                s.setEnabled(false);
                s.setSummary(p + " - required: disabling it stops the panel from booting");
                cr.addPreference(s);
                continue;
            }
            int st = pm.getApplicationEnabledSetting(p);
            s.setChecked(st == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT ? ai.enabled
                    : st == PackageManager.COMPONENT_ENABLED_STATE_ENABLED);
            s.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
                public boolean onPreferenceChange(Preference x, Object v) {
                    boolean en = (Boolean) v;
                    try {
                        ctx().getPackageManager().setApplicationEnabledSetting(ai.packageName,
                                en ? PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                                   : PackageManager.COMPONENT_ENABLED_STATE_DISABLED, 0);
                        CrustyService.event("crestron app " + ai.packageName + (en ? " enabled" : " disabled"));
                        return true;
                    } catch (Exception e) {
                        Toast.makeText(ctx(), "nope, that failed: " + e, Toast.LENGTH_LONG).show();
                        return false;
                    }
                }
            });
            cr.addPreference(s);
        }

        // ---- security
        PreferenceCategory sec = category(root, "security");
        final EditTextPreference pin = new EditTextPreference(ctx());
        pin.setPersistent(false);
        pin.setTitle(Prefs.hasPin(ctx()) ? "change PIN" : "set PIN");
        pin.setSummary(Prefs.hasPin(ctx()) ? "crusty is PIN protected (empty = remove PIN)" : "crusty is not protected, anyone can mess with it");
        pin.getEditText().setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        pin.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                Prefs.setPin(ctx(), ((String) v).trim());
                CrustyService.event(((String) v).trim().length() > 0 ? "PIN set" : "PIN removed");
                setPreferenceScreen(buildRoot());
                return false;
            }
        });
        sec.addPreference(pin);
        final Preference rootCheck = action("check root access", Root.status(), null);
        rootCheck.setOnPreferenceClickListener(new Preference.OnPreferenceClickListener() {
            public boolean onPreferenceClick(Preference x) {
                rootCheck.setSummary("checking - if Superuser asks, allow crusty ...");
                Root.check(new Root.Result() {
                    public void done(boolean root, String text) {
                        if (getActivity() == null) return;
                        rootCheck.setSummary((root ? "root works - " : "no root - ") + Root.status());
                        new AlertDialog.Builder(ctx()).setTitle(root ? "root works" : "no root")
                                .setMessage(text).setPositiveButton(android.R.string.ok, null).show();
                    }
                });
                return true;
            }
        });
        sec.addPreference(rootCheck);
        SwitchPreference rootBoot = new SwitchPreference(ctx());
        rootBoot.setPersistent(false);
        rootBoot.setTitle("root daemon at boot");
        rootBoot.setSummary("starts su --daemon at boot (apps still need a grant in Superuser) - takes effect after a reboot");
        rootBoot.setChecked(!Root.DISABLED.exists());
        rootBoot.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                boolean on = (Boolean) v;
                boolean ok = on ? (!Root.DISABLED.exists() || Root.DISABLED.delete())
                        : CrustyService.write(Root.DISABLED, "1\n", false);
                CrustyService.event("root daemon at boot: " + (on ? "on" : "off") + (ok ? "" : " (FAILED)"));
                return ok;
            }
        });
        sec.addPreference(rootBoot);
        sec.addPreference(action("remote shell (ssh)", Root.sshStatus(), new Runnable() {
            public void run() {
                String log = CrustyService.read(Root.SSH_LOG);
                if (log != null && log.length() > 3000) log = log.substring(log.length() - 3000);
                new AlertDialog.Builder(ctx()).setTitle("ssh")
                        .setMessage(Root.sshStatus() + "\n\naddresses: " + Root.addresses()
                                + "\n\nlogin with a key only, no passwords here (config/ssh/authorized_keys on the PC, "
                                + "tools/mod-data.py puts it on the card).\n\nboot hook:\n" + Root.bootLogTail()
                                + "\n\nssh log:\n" + (log == null ? "(none)" : log.trim()))
                        .setPositiveButton(android.R.string.ok, null).show();
            }
        }));
        SwitchPreference sshBoot = new SwitchPreference(ctx());
        sshBoot.setPersistent(false);
        sshBoot.setTitle("ssh server at boot");
        sshBoot.setSummary("takes effect after a reboot");
        sshBoot.setChecked(!Root.SSH_DISABLED.exists());
        sshBoot.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                boolean on = (Boolean) v;
                boolean ok = on ? (!Root.SSH_DISABLED.exists() || Root.SSH_DISABLED.delete())
                        : CrustyService.write(Root.SSH_DISABLED, "1\n", false);
                CrustyService.event("ssh at boot: " + (on ? "on" : "off") + (ok ? "" : " (FAILED)"));
                return ok;
            }
        });
        sec.addPreference(sshBoot);

        // ---- logging / debug
        PreferenceScreen dbg = getPreferenceManager().createPreferenceScreen(ctx());
        dbg.setTitle("logging & debug");
        dbg.setSummary("logs in /data/crusty/logs (SD card), snapshots, tests");
        root.addPreference(dbg);
        dbg.addPreference(sw("save logcat", Prefs.LOG_LOGCAT, true, null));
        dbg.addPreference(sw("save kernel log", Prefs.LOG_KERNEL, true, null));
        dbg.addPreference(sw("periodic state snapshots", Prefs.LOG_SNAPSHOTS, true, null));
        dbg.addPreference(action("save snapshot now", null, new Runnable() {
            public void run() {
                ctx().startService(new Intent(ctx(), CrustyService.class)
                        .setAction(CrustyService.ACTION_SNAPSHOT).putExtra("why", "manual"));
                Toast.makeText(ctx(), "snapshot is on its way to the SD card", Toast.LENGTH_SHORT).show();
            }
        }));
        dbg.addPreference(action("test: list HOME apps", null, new Runnable() {
            public void run() { new AlertDialog.Builder(ctx()).setMessage(homeInfo()).show(); }
        }));

        // ---- system
        PreferenceCategory sys = category(root, "system");
        sys.addPreference(action("reboot", null, new Runnable() {
            public void run() {
                CrustyService.event("reboot requested from app");
                ((PowerManager) ctx().getSystemService(Context.POWER_SERVICE)).reboot(null);
            }
        }));
        sys.addPreference(action("reboot to golden mode", "maintenance mode: back up, install or restore the "
                + "eMMC with a USB stick. the reboot after that lands back here.", new Runnable() {
            public void run() {
                new AlertDialog.Builder(ctx()).setTitle("reboot to golden mode?")
                        .setMessage("the panel restarts into crustys maintenance mode (from the SD card).")
                        .setNegativeButton(android.R.string.cancel, null)
                        .setPositiveButton("reboot", new android.content.DialogInterface.OnClickListener() {
                            public void onClick(android.content.DialogInterface d, int w) { rebootToGolden(); }
                        }).show();
            }
        }));
        sys.addPreference(action("power off", "unplug / replug to start it again", new Runnable() {
            public void run() {
                CrustyService.event("power off requested from app");
                Intent i = new Intent("android.intent.action.ACTION_REQUEST_SHUTDOWN");
                i.putExtra("android.intent.extra.KEY_CONFIRM", false);
                i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(i);
            }
        }));
        return root;
    }

    // asks the root boot hook (crusty-boot.sh) to set boot_retry=10 through a request file, waits for its "ready" and only then reboots
    private void rebootToGolden() {
        final java.io.File run = new java.io.File(CrustyService.ROOT, "run");
        final java.io.File status = new java.io.File(run, "golden-status");
        status.delete();
        if (!CrustyService.write(new java.io.File(run, "golden-request"), "1\n", false)) {
            new AlertDialog.Builder(ctx()).setMessage("cant request it: " + run + " is missing. "
                    + "this needs the crusty eMMC update (its root boot hook).").show();
            return;
        }
        CrustyService.event("reboot to golden mode requested");
        Toast.makeText(ctx(), "preparing golden mode ...", Toast.LENGTH_SHORT).show();
        final android.os.Handler h = new android.os.Handler();
        h.postDelayed(new Runnable() {
            int tries;
            public void run() {
                String st = CrustyService.read(status);
                if (st != null && st.trim().equals("ready")) {
                    CrustyService.event("golden mode armed, rebooting");
                    ((PowerManager) ctx().getSystemService(Context.POWER_SERVICE)).reboot(null);
                } else if (st != null) {
                    new AlertDialog.Builder(ctx()).setMessage("golden mode: " + st.trim()).show();
                } else if (++tries < 20) {
                    h.postDelayed(this, 500);
                } else {
                    new AlertDialog.Builder(ctx()).setMessage("no answer from the root boot hook. right after "
                            + "a boot it waits until crestrons boot scripts are done, try again in a minute.").show();
                }
            }
        }, 500);
    }

    // =================================================================== profile

    private PreferenceScreen buildProfile(final String pkg) {
        PreferenceScreen root = getPreferenceManager().createPreferenceScreen(ctx());
        root.addPreference(info(appLabel(pkg), "button actions while this app is in front. "
                + "\"(default)\" = use the normal mapping."));
        for (int i = 0; i < Prefs.BUTTONS.length; i++) {
            PreferenceCategory c = category(root, Prefs.BUTTON_LABELS[i]);
            for (boolean lp : new boolean[] { false, true }) {
                actionPicker(c, lp ? "long press" : "short press",
                        Prefs.profileKey(pkg, Prefs.BUTTONS[i], lp), Prefs.profileAppKey(pkg, Prefs.BUTTONS[i], lp),
                        Prefs.INHERIT, true);
            }
        }
        root.addPreference(action("delete this profile", null, new Runnable() {
            public void run() {
                Set<String> set = Prefs.profiles(ctx());
                set.remove(pkg);
                android.content.SharedPreferences.Editor e = Prefs.get(ctx()).edit().putStringSet(Prefs.PROFILES, set);
                for (String k : Prefs.get(ctx()).getAll().keySet()) {
                    if (k.startsWith("profile." + pkg + ".")) e.remove(k);
                }
                e.apply();
                getActivity().finish();
            }
        }));
        return root;
    }

    private void openProfile(String pkg) {
        startActivity(new Intent(ctx(), MainActivity.class).putExtra(MainActivity.EXTRA_PROFILE, pkg));
    }

    // =================================================================== builders

    private void actionPicker(PreferenceGroup parent, String title, String key, String appKey, String def, boolean inherit) {
        String[] labels = Prefs.ACTION_LABELS, values = Prefs.ACTIONS;
        if (inherit) {
            labels = concat(new String[] { "(default)" }, labels);
            values = concat(new String[] { Prefs.INHERIT }, values);
        }
        final ListPreference l = list(title, key, def, labels, values);
        final ListPreference app = appList(title + ": app", appKey, false);
        parent.addPreference(l);
        parent.addPreference(app);
        app.setEnabled("app".equals(Prefs.str(ctx(), key, def)));
        l.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                app.setEnabled("app".equals(v));
                return true;
            }
        });
    }

    private PreferenceCategory category(PreferenceGroup parent, String title) {
        PreferenceCategory c = new PreferenceCategory(ctx());
        c.setTitle(title);
        parent.addPreference(c);
        return c;
    }

    private Preference info(String title, String summary) {
        Preference p = new Preference(ctx());
        p.setTitle(title);
        if (summary != null) p.setSummary(summary);
        p.setSelectable(false);
        return p;
    }

    private Preference action(String title, String summary, final Runnable r) {
        Preference p = new Preference(ctx());
        p.setTitle(title);
        if (summary != null) p.setSummary(summary);
        p.setOnPreferenceClickListener(new Preference.OnPreferenceClickListener() {
            public boolean onPreferenceClick(Preference x) { if (r != null) r.run(); return true; }
        });
        return p;
    }

    private SwitchPreference sw(String title, String key, boolean def, String summary) {
        SwitchPreference s = new SwitchPreference(ctx());
        s.setKey(key);
        s.setTitle(title);
        s.setDefaultValue(def);
        s.setChecked(Prefs.bool(ctx(), key, def));
        if (summary != null) s.setSummary(summary);
        return s;
    }

    private ListPreference list(String title, String key, String def, String[] labels, String[] values) {
        ListPreference l = new ListPreference(ctx());
        l.setKey(key);
        l.setTitle(title);
        l.setDialogTitle(title);
        l.setEntries(labels);
        l.setEntryValues(values);
        l.setDefaultValue(def);
        l.setValue(Prefs.str(ctx(), key, def));
        l.setSummary("%s");
        return l;
    }

    private EditTextPreference number(String title, String key, String def) {
        final EditTextPreference e = new EditTextPreference(ctx());
        e.setKey(key);
        e.setTitle(title);
        e.setDialogTitle(title);
        e.setDefaultValue(def);
        e.setText(Prefs.str(ctx(), key, def));
        e.setSummary(Prefs.str(ctx(), key, def));
        e.getEditText().setInputType(InputType.TYPE_CLASS_NUMBER);
        e.setOnPreferenceChangeListener(new Preference.OnPreferenceChangeListener() {
            public boolean onPreferenceChange(Preference p, Object v) {
                if (((String) v).trim().length() == 0) return false;
                p.setSummary((String) v);
                return true;
            }
        });
        return e;
    }

    private ListPreference appList(String title, String key, boolean withNone) {
        String[] labels = mAppLabels, values = mAppPkgs;
        if (withNone) {
            labels = concat(new String[] { "(none)" }, labels);
            values = concat(new String[] { "" }, values);
        }
        ListPreference l = new ListPreference(ctx());
        if (key != null) {
            l.setKey(key);
            l.setValue(Prefs.str(ctx(), key, ""));
        }
        l.setTitle(title);
        l.setDialogTitle(title);
        l.setEntries(labels);
        l.setEntryValues(values);
        l.setDefaultValue("");
        l.setSummary("%s");
        return l;
    }

    // =================================================================== helpers

    private void loadApps() {
        PackageManager pm = ctx().getPackageManager();
        List<ResolveInfo> ris = pm.queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0);
        final List<String[]> apps = new ArrayList<String[]>();
        for (ResolveInfo ri : ris) {
            String p = ri.activityInfo.packageName;
            if (p.equals(ctx().getPackageName())) continue;
            boolean dup = false;
            for (String[] a : apps) if (a[1].equals(p)) dup = true;
            if (!dup) apps.add(new String[] { String.valueOf(ri.loadLabel(pm)), p });
        }
        Collections.sort(apps, new Comparator<String[]>() {
            public int compare(String[] a, String[] b) { return a[0].compareToIgnoreCase(b[0]); }
        });
        mAppLabels = new String[apps.size()];
        mAppPkgs = new String[apps.size()];
        for (int i = 0; i < apps.size(); i++) {
            mAppLabels[i] = apps.get(i)[0];
            mAppPkgs[i] = apps.get(i)[1];
        }
    }

    private String appLabel(String pkg) {
        for (int i = 0; i < mAppPkgs.length; i++) if (mAppPkgs[i].equals(pkg)) return mAppLabels[i];
        return pkg;
    }

    private String status() {
        StringBuilder sb = new StringBuilder();
        sb.append("crusty 0.12 - logs ").append(CrustyService.sBootDir != null ? CrustyService.sBootDir.getName() : "-");
        sb.append(" - wakelock ").append(CrustyService.sWakeLockHeld ? "held" : "off");
        if (Kiosk.active(ctx())) sb.append(" - KIOSK");
        if (Golden.active()) sb.append(" - GOLDEN MODE");
        return sb.toString();
    }

    private String homeInfo() {
        PackageManager pm = ctx().getPackageManager();
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        StringBuilder sb = new StringBuilder("HOME candidates:\n");
        for (ResolveInfo ri : pm.queryIntentActivities(home, 0)) {
            sb.append("  ").append(ri.activityInfo.packageName).append('/').append(ri.activityInfo.name).append('\n');
        }
        ResolveInfo r = pm.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY);
        sb.append("resolves to: ").append(r == null ? "null" : r.activityInfo.packageName + "/" + r.activityInfo.name);
        CrustyService.event(sb.toString().replace('\n', ' '));
        return sb.toString();
    }

    private static List<String> sorted(Set<String> s) {
        List<String> l = new ArrayList<String>(s);
        Collections.sort(l);
        return l;
    }

    private static String[] concat(String[] a, String[] b) {
        String[] r = new String[a.length + b.length];
        System.arraycopy(a, 0, r, 0, a.length);
        System.arraycopy(b, 0, r, a.length, b.length);
        return r;
    }
}
