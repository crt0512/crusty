package dev.crusty.companion;

import android.os.Handler;
import android.os.Looper;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;

// root status, plus a check whether it really works
// root here means phh's Superuser from the crusty eMMC update: /system/xbin/su, a root daemon ("su --daemon", started by /system/bin/crusty-boot.sh, output in /data/crusty/boot-root.log) and the manager app me.phh.superuser which asks you whether an app gets root
final class Root {
    static final File SU = new File("/system/xbin/su");
    static final File BOOT_LOG = new File(CrustyService.ROOT, "boot-root.log");
    static final File DISABLED = new File(CrustyService.CONFIG, "root_disabled");

    interface Result { void done(boolean root, String text); }

    private Root() {}

    // pid of the running "su --daemon", or -1
    static int daemonPid() {
        File[] procs = new File("/proc").listFiles();
        if (procs == null) return -1;
        for (File p : procs) {
            String n = p.getName();
            if (n.isEmpty() || !Character.isDigit(n.charAt(0))) continue;
            String cmd = CrustyService.read(new File(p, "cmdline"));
            if (cmd != null && cmd.contains("su") && cmd.contains("--daemon")) return Integer.parseInt(n);
        }
        return -1;
    }

    // the last boots part of the boot hook log, thats where you'd see the su daemon faceplanting
    static String bootLogTail() {
        String s = CrustyService.read(BOOT_LOG);
        if (s == null) return "no " + BOOT_LOG;
        String[] lines = s.trim().split("\n");
        int start = lines.length - 1;
        while (start > 0 && !lines[start].startsWith("== ")) start--;   // every boot starts with a "== " line, we only want the last one
        StringBuilder sb = new StringBuilder();
        for (int i = start; i < lines.length; i++) sb.append(lines[i]).append('\n');
        return sb.toString().trim();
    }

    // ---- ssh (dropbear, started by crusty-boot.sh, keys in /data/crusty/ssh, root only)
    static final File SSH_DISABLED = new File(CrustyService.CONFIG, "ssh_disabled");
    static final File SSH_LOG = new File(CrustyService.ROOT, "ssh.log");

    static int sshPid() {
        File[] procs = new File("/proc").listFiles();
        if (procs == null) return -1;
        for (File p : procs) {
            String n = p.getName();
            if (n.isEmpty() || !Character.isDigit(n.charAt(0))) continue;
            String cmd = CrustyService.read(new File(p, "cmdline"));
            if (cmd != null && cmd.startsWith("/system/xbin/dropbearmulti") && cmd.contains("-p")) return Integer.parseInt(n);
        }
        return -1;
    }

    static String addresses() {
        StringBuilder sb = new StringBuilder();
        try {
            for (java.net.NetworkInterface ni : java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces())) {
                if (ni.isLoopback() || !ni.isUp()) continue;
                for (java.net.InetAddress a : java.util.Collections.list(ni.getInetAddresses())) {
                    if (a instanceof java.net.Inet4Address) sb.append(sb.length() > 0 ? ", " : "").append(a.getHostAddress());
                }
            }
        } catch (Exception e) { }
        return sb.length() > 0 ? sb.toString() : "no network";
    }

    static String sshStatus() {
        if (!new File("/system/xbin/dropbearmulti").exists()) return "not installed (comes with the eMMC update)";
        if (SSH_DISABLED.exists()) return "disabled";
        int pid = sshPid();
        if (pid > 0) return "running: ssh root@" + addresses().split(",")[0];
        return "not running (details below)";
    }

    static String status() {
        if (!SU.exists()) return "no su binary (install the crusty eMMC update in golden mode)";
        if (DISABLED.exists()) return "disabled at boot (" + DISABLED + ")";
        int pid = daemonPid();
        return pid > 0 ? "su daemon running (pid " + pid + ")" : "su daemon NOT running - tap for the details";
    }

    // runs "su -c id" off the main thread, the first time Superuser pops its grant dialog for dev.crusty.companion and humans are slow so it gets up to 60 s
    static void check(final Result cb) {
        final Handler main = new Handler(Looper.getMainLooper());
        new Thread("crusty-root-check") {
            public void run() {
                final StringBuilder out = new StringBuilder();
                boolean root = false;
                if (!SU.exists()) {
                    out.append("no ").append(SU).append(".\ninstall the crusty eMMC update in golden mode.");
                } else {
                    Process p = null;
                    try {
                        p = new ProcessBuilder(SU.getPath(), "-c", "id").redirectErrorStream(true).start();
                        p.getOutputStream().close();
                        final Process proc = p;
                        Thread killer = new Thread() {
                            public void run() {
                                try { Thread.sleep(60000); proc.destroy(); } catch (InterruptedException e) { }
                            }
                        };
                        killer.start();
                        BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                        String id = "";
                        for (String l; (l = r.readLine()) != null; ) id += l + "\n";
                        int rc = p.waitFor();
                        killer.interrupt();
                        root = rc == 0 && id.contains("uid=0");
                        out.append(root ? "root works, BOOM!\n\n" : "no root (exit code " + rc + ")\n\n");
                        out.append("su -c id:\n").append(id.trim().isEmpty() ? "(no output)" : id.trim());
                    } catch (Exception e) {
                        out.append("su didnt even start: ").append(e.getMessage());
                    } finally {
                        if (p != null) p.destroy();
                    }
                }
                if (!root) {
                    int pid = daemonPid();
                    out.append("\n\nsu daemon: ").append(pid > 0 ? "running (pid " + pid + ")" : "NOT running");
                    if (DISABLED.exists()) out.append(" - disabled at boot");
                    out.append("\nif Superuser asked: allow dev.crusty.companion. said no before? "
                            + "change it in the Superuser app.");
                    out.append("\n\nboot hook log:\n").append(bootLogTail());
                }
                final boolean ok = root;
                CrustyService.event("root check: " + (ok ? "uid 0 ok" : "no root"));
                main.post(new Runnable() { public void run() { cb.done(ok, out.toString()); } });
            }
        }.start();
    }
}
