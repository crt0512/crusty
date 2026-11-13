package dev.crusty.companion;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.provider.Settings;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

// keeps the clock right, because this panel never had the correct time
// androids network time is switched off (Settings.Global auto_time=0) and crestrons own NTP daemon (ntpsec) falls over at startup ("unable to bind ... EXITING") so the clock just sits at crestrons build date
// with a 2024 clock pretty much every current TLS certificate is "not yet valid" = SSL errors everywhere
// so we turn androids network time back on (auto_time=1, ntp_server) and as insurance do SNTP ourselves and set the clock (the system uid has SET_TIME)
// that happens at start, retrying every minute until it works, then every 6 hours
final class NtpSync {
    private NtpSync() { }

    private static Handler sHandler;
    static volatile String sLast = "not synced yet";

    static void start(final Context c) {
        if (!Prefs.bool(c, Prefs.TIME_SYNC, true)) {
            sLast = "off";
            return;
        }
        String server = server(c);
        try {
            Settings.Global.putInt(c.getContentResolver(), Settings.Global.AUTO_TIME, 1);
            Settings.Global.putString(c.getContentResolver(), "ntp_server", server);
        } catch (Exception e) {
            CrustyService.event("time: cant enable network time: " + e);
        }
        if (sHandler == null) {
            HandlerThread t = new HandlerThread("crusty-ntp");
            t.start();
            sHandler = new Handler(t.getLooper());
        }
        sHandler.removeCallbacksAndMessages(null);
        sHandler.post(new Runnable() {
            public void run() {
                boolean ok = syncOnce(c);
                sHandler.postDelayed(this, ok ? 6 * 3600 * 1000L : 60 * 1000L);
            }
        });
    }

    static void syncNow(final Context c) {
        if (sHandler == null) { start(c); return; }
        sHandler.post(new Runnable() { public void run() { syncOnce(c); } });
    }

    static String server(Context c) {
        String s = Prefs.str(c, Prefs.TIME_SERVER, "pool.ntp.org").trim();
        return s.length() > 0 ? s : "pool.ntp.org";
    }

    // one SNTP request (RFC 4330), true = the clock is right now
    static boolean syncOnce(Context c) {
        String server = server(c);
        DatagramSocket sock = null;
        try {
            InetAddress addr = InetAddress.getByName(server);
            sock = new DatagramSocket();
            sock.setSoTimeout(5000);
            byte[] buf = new byte[48];
            buf[0] = 0x1b;                                   // LI=0, VN=3, mode=3 (client)
            long t1 = System.currentTimeMillis();
            long e1 = SystemClock.elapsedRealtime();
            writeTs(buf, 40, t1);                            // transmit timestamp
            sock.send(new DatagramPacket(buf, buf.length, addr, 123));
            DatagramPacket resp = new DatagramPacket(new byte[48], 48);
            sock.receive(resp);
            long e4 = SystemClock.elapsedRealtime();
            long t4 = t1 + (e4 - e1);
            byte[] r = resp.getData();
            int mode = r[0] & 7, stratum = r[1] & 0xff;
            if (mode != 4 && mode != 5 || stratum == 0 || stratum > 15) {
                sLast = "garbage reply from " + server + " (mode " + mode + ", stratum " + stratum + ")";
                CrustyService.event("time: " + sLast);
                return false;
            }
            long t2 = readTs(r, 32), t3 = readTs(r, 40);     // server receive / transmit
            long offset = ((t2 - t1) + (t3 - t4)) / 2;
            long rtt = (t4 - t1) - (t3 - t2);
            if (Math.abs(offset) > 2000) {
                long now = System.currentTimeMillis() + offset;
                boolean set = SystemClock.setCurrentTimeMillis(now);
                CrustyService.event("time: clock was off by " + offset / 1000 + " s -> "
                        + (set ? "set to " + new java.util.Date(now) : "setting it FAILED") + " (" + server + ")");
                if (!set) { sLast = "cant set the clock"; return false; }
            }
            sLast = "synced with " + server + " (offset " + offset + " ms, rtt " + rtt + " ms) at "
                    + new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US).format(new java.util.Date());
            return true;
        } catch (Exception e) {
            sLast = "failed (" + server + "): " + e.getClass().getSimpleName() + ": " + e.getMessage();
            return false;
        } finally {
            if (sock != null) sock.close();
        }
    }

    // NTP timestamps are seconds since 1900 (32 bit) + fraction (32 bit) because unix time was too mainstream
    private static final long OFFSET_1900_TO_1970 = 2208988800L;

    private static long readTs(byte[] b, int o) {
        long sec = ((b[o] & 0xffL) << 24) | ((b[o + 1] & 0xffL) << 16) | ((b[o + 2] & 0xffL) << 8) | (b[o + 3] & 0xffL);
        long frac = ((b[o + 4] & 0xffL) << 24) | ((b[o + 5] & 0xffL) << 16) | ((b[o + 6] & 0xffL) << 8) | (b[o + 7] & 0xffL);
        return (sec - OFFSET_1900_TO_1970) * 1000L + (frac * 1000L >> 32);
    }

    private static void writeTs(byte[] b, int o, long ms) {
        long sec = ms / 1000L + OFFSET_1900_TO_1970;
        long frac = (ms % 1000L) * 0x100000000L / 1000L;
        for (int i = 0; i < 4; i++) b[o + i] = (byte) (sec >> (24 - 8 * i));
        for (int i = 0; i < 4; i++) b[o + 4 + i] = (byte) (frac >> (24 - 8 * i));
    }
}
