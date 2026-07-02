package com.grkndev.clipboard;

import android.content.ClipData;
import android.os.Binder;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayDeque;

/**
 * Privileged clipboard agent — runs as shell UID (2000) via `app_process`,
 * started by the app over self-ADB. Bridges the system clipboard to the app
 * over a localhost socket (NDJSON).
 *
 *   app  --(127.0.0.1:PORT)-->  this process (shell UID)  -->  IClipboard
 *
 *   app -> jar : {"cmd":"auth","secret":"..."}   (REQUIRED first line when launched with a secret)
 *   jar -> app : {"type":"clip","text":"...","ts":1234}
 *   app -> jar : {"cmd":"write","text":"..."}
 *   app -> jar : {"cmd":"log"}   ->   jar replies {"type":"log","text":"...buffered log..."}
 *
 * Auth: any app holding INTERNET can reach 127.0.0.1, so serving unauthenticated would let a
 * hostile app read every clipboard change and inject writes. The launcher passes a random
 * secret as the second arg; a connection gets NOTHING (not even the initial clip sync) until
 * its first line is a matching {"cmd":"auth"}. No secret arg -> legacy open mode.
 *
 * No crypto here — plaintext over localhost. E2E happens in the app layer.
 * Launch: CLASSPATH=/data/local/tmp/clipboard-agent.dex app_process /system/bin \
 *         com.grkndev.clipboard.ClipboardAgent <PORT> [SECRET]
 */
public class ClipboardAgent {

    static final String PKG = "com.android.shell";
    static volatile String lastSeen = null;
    static Object svc; // IClipboard

    // single connected app client
    static volatile OutputStream out;
    static final Object outLock = new Object();

    // Bounded in-memory copy of this process's log, served to the app over the bridge on
    // {"cmd":"log"}. Lets "Device Log" read the daemon's own diagnostics with no adb / wireless
    // debugging when the daemon is up — the localhost pipe is already open.
    static final ArrayDeque<String> logBuf = new ArrayDeque<>();
    static final int LOG_BUF_MAX_LINES = 500;

    // ---------------------------------------------------------------------
    // IClipboard reflection (unchanged core from the original proof)
    // ---------------------------------------------------------------------
    static Object svc() throws Exception {
        if (svc == null) {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "clipboard");
            Class<?> stub = Class.forName("android.content.IClipboard$Stub");
            svc = stub.getMethod("asInterface", IBinder.class).invoke(null, b);
        }
        return svc;
    }

    static Method find(String name) throws Exception {
        for (Method m : svc().getClass().getMethods()) {
            if (m.getName().equals(name)) {
                return m;
            }
        }
        throw new NoSuchMethodException(name);
    }

    // ClipData->clip, first interface param->listener, first String->PKG, next String->null, int->0
    static Object[] args(Method m, ClipData clip, Object listener) {
        Class<?>[] t = m.getParameterTypes();
        Object[] a = new Object[t.length];
        boolean firstStr = true, placedListener = false;
        for (int i = 0; i < t.length; i++) {
            if (t[i] == ClipData.class) {
                a[i] = clip;
            } else if (!placedListener && t[i].isInterface()) {
                a[i] = listener;
                placedListener = true;
            } else if (t[i] == String.class) {
                a[i] = firstStr ? PKG : null;
                firstStr = false;
            } else if (t[i] == int.class) {
                a[i] = 0;
            } else {
                a[i] = null;
            }
        }
        return a;
    }

    static void write(CharSequence text) throws Exception {
        Method m = find("setPrimaryClip");
        m.invoke(svc(), args(m, ClipData.newPlainText("l", text), null));
    }

    static CharSequence read() throws Exception {
        Method m = find("getPrimaryClip");
        ClipData c = (ClipData) m.invoke(svc(), args(m, null, null));
        return (c == null || c.getItemCount() == 0) ? null : c.getItemAt(0).getText();
    }

    // ---------------------------------------------------------------------
    // localhost socket bridge
    // ---------------------------------------------------------------------
    static void send(JSONObject o) {
        synchronized (outLock) {
            if (out == null) return;
            try {
                out.write((o.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
            } catch (Exception e) {
                out = null;
            }
        }
    }

    static void emitClip(String text) {
        try {
            JSONObject o = new JSONObject();
            o.put("type", "clip");
            o.put("text", text);
            o.put("ts", System.currentTimeMillis());
            send(o);
        } catch (Exception ignored) {
        }
    }

    static void handleCommand(String line) {
        try {
            JSONObject o = new JSONObject(line);
            String cmd = o.optString("cmd");
            if ("write".equals(cmd)) {
                String text = o.optString("text");
                lastSeen = text;       // suppress echo of our own write
                write(text);
                log("wrote from app");
            } else if ("log".equals(cmd)) {
                sendLog();
            }
        } catch (Exception e) {
            log("cmd parse error: " + e.getMessage());
        }
    }

    // Reply to {"cmd":"log"} with this process's buffered log (one JSON line, newlines escaped).
    static void sendLog() {
        StringBuilder sb = new StringBuilder();
        synchronized (logBuf) {
            for (String l : logBuf) {
                sb.append(l).append('\n');
            }
        }
        try {
            JSONObject o = new JSONObject();
            o.put("type", "log");
            o.put("text", sb.toString());
            send(o);
        } catch (Exception ignored) {
        }
    }

    static void log(String s) {
        String line = "[clip] " + s;
        // Flush every line: app_process redirects stdout to clip.log, and a
        // buffered stream would swallow startup diagnostics if the process later
        // stalls or is killed — which is exactly when the log matters most.
        System.out.println(line);
        System.out.flush();
        synchronized (logBuf) {
            logBuf.addLast(line);
            while (logBuf.size() > LOG_BUF_MAX_LINES) {
                logBuf.removeFirst();
            }
        }
    }

    /** Constant-time check that a first line is a {"cmd":"auth"} carrying the launch secret. */
    static boolean authOk(String line, String secret) {
        try {
            JSONObject o = new JSONObject(line);
            if (!"auth".equals(o.optString("cmd"))) {
                return false;
            }
            return MessageDigest.isEqual(
                    o.optString("secret").getBytes(StandardCharsets.UTF_8),
                    secret.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            return false;
        }
    }

    static void serve(int port, String secret) throws Exception {
        ServerSocket server = new ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"));
        log("listening 127.0.0.1:" + port + (secret != null ? " (auth required)" : ""));
        while (true) {
            Socket s = server.accept();
            log("client connected");
            try {
                BufferedReader r = new BufferedReader(
                        new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                // Auth gate BEFORE anything is served (no `out`, no initial clip sync). The
                // read timeout also stops a silent client from camping the single slot.
                if (secret != null) {
                    s.setSoTimeout(5000);
                    String first = r.readLine();
                    if (first == null || !authOk(first, secret)) {
                        log("client rejected (bad or missing auth)");
                        continue; // finally closes the socket, loop re-accepts
                    }
                    s.setSoTimeout(0);
                    log("client authenticated");
                }
                synchronized (outLock) {
                    out = s.getOutputStream();
                }
                // send current clipboard once on connect (initial sync)
                try {
                    CharSequence cur = read();
                    if (cur != null) {
                        lastSeen = cur.toString();
                        emitClip(cur.toString());
                    }
                } catch (Exception ignored) {
                }
                // reader loop for this connection
                String line;
                while ((line = r.readLine()) != null) {
                    handleCommand(line);
                }
            } catch (Exception e) {
                log("client read end: " + e.getMessage());
            } finally {
                synchronized (outLock) {
                    out = null;
                }
                try {
                    s.close();
                } catch (Exception ignored) {
                }
                log("client disconnected");
            }
        }
    }

    // ---------------------------------------------------------------------
    public static void main(String[] x) throws Exception {
        final int port = (x.length > 0) ? Integer.parseInt(x[0]) : 53123;
        // Bridge-auth secret (never logged). Absent -> legacy open mode, for a stale launcher.
        final String secret = (x.length > 1 && !x[1].isEmpty()) ? x[1] : null;
        Looper.prepareMainLooper();
        log("server up. uid=" + android.os.Process.myUid() + " port=" + port);

        // Bind the localhost socket FIRST, on its own thread, before ANY privileged
        // clipboard IPC. getPrimaryClip/setPrimaryClip under shell UID can block or
        // throw on some OEM builds (One UI), and the app's waitForDaemon only checks
        // this socket — a launch that stalls or dies before binding loops the
        // pairing/reconnect screen (issue #5). Keep the bind independent of any
        // clipboard reflection so the daemon always comes "up" for the app.
        new Thread(() -> {
            try {
                serve(port, secret);
            } catch (Exception e) {
                log("serve fatal: " + e.getMessage());
            }
        }, "clip-socket").start();

        // Best-effort, non-fatal self-test. Read-only (never clobber the user's
        // clipboard) and off the main thread so a stalled privileged IPC can't
        // wedge startup. Previously this wrote+read on the main thread BEFORE the
        // bind, so a hang here left the socket unbound and the log empty.
        new Thread(() -> {
            try {
                CharSequence cur = read();
                log("selftest read ok (len=" + (cur == null ? 0 : cur.length()) + ")");
            } catch (Throwable t) {
                log("selftest read failed (non-fatal): " + t);
            }
        }, "clip-selftest").start();

        // Register the system clip-changed listener. Non-fatal: if this reflection
        // fails on a given OS the socket bridge (app->phone writes + initial sync)
        // still works, and the daemon stays up instead of dying before Looper.loop.
        try {
            // real Binder that receives the system's dispatchPrimaryClipChanged callback
            final Binder realBinder = new Binder() {
                @Override
                protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                    if (code == IBinder.FIRST_CALL_TRANSACTION) { // dispatchPrimaryClipChanged
                        try {
                            CharSequence t = read();
                            if (t != null) {
                                String s = t.toString();
                                if (!s.equals(lastSeen)) {     // ignore our own writes
                                    lastSeen = s;
                                    log("captured -> emit");
                                    emitClip(s);
                                }
                            } else {
                                log("clip changed but empty/unreadable");
                            }
                        } catch (Exception e) {
                            log("read error: " + e.getMessage());
                        }
                        if (reply != null) {
                            reply.writeNoException();
                        }
                        return true;
                    }
                    return super.onTransact(code, data, reply, flags);
                }
            };

            // dynamic-proxy listener; reflection type-check accepts the proxy
            Class<?> listenerItf = Class.forName("android.content.IOnPrimaryClipChangedListener");
            Object listener = Proxy.newProxyInstance(
                    ClipboardAgent.class.getClassLoader(),
                    new Class<?>[]{listenerItf},
                    (proxy, method, a) -> {
                        switch (method.getName()) {
                            case "asBinder":
                                return realBinder; // system transacts to the real binder
                            case "toString":
                                return "ClipListener";
                            case "hashCode":
                                return System.identityHashCode(proxy);
                            case "equals":
                                return proxy == (a == null ? null : a[0]);
                            default:
                                return null;
                        }
                    });

            Method add = find("addPrimaryClipChangedListener");
            add.invoke(svc(), args(add, null, listener));
            log("listener active. copy something on the phone...");
        } catch (Throwable t) {
            log("listener registration failed (non-fatal): " + t);
        }

        Looper.loop();
    }
}
