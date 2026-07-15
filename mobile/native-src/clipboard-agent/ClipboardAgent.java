package com.grkndev.clipboard;

import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;
import android.os.Binder;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Base64;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
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
 *   jar -> app : {"type":"image","mime":"image/png","data":"<base64>","ts":1234}
 *   app -> jar : {"cmd":"write","text":"..."}
 *   app -> jar : {"cmd":"log"}   ->   jar replies {"type":"log","text":"...buffered log..."}
 *
 * Image capture: an image copied on the phone lands on the clipboard as a content:// URI, not
 * text. Reading its bytes needs a ContentResolver, which needs a Context — this app_process has
 * none by default. We build a bare `ActivityStream`/`ActivityThread` and call `getSystemContext()`
 * (NOT `systemMain()`, which would re-prepare the main Looper we already own) to get a shell-uid
 * resolver, then `openInputStream(uri)`. The clipboard read-grant follows the getPrimaryClip
 * caller (this shell process), so the resolver can read the URI. Fails soft: if the context can't
 * be built (some OEM builds), text sync still works and images are simply skipped.
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
    /** URI of the last image we emitted, so a repeated clip-changed transact for the same image
     *  doesn't re-send it. Echo of a Mac→phone image is suppressed app-side (by content hash). */
    static volatile String lastImageKey = null;
    static volatile Object svc; // IClipboard; volatile + DCL — raced by the startup threads
    static final Object svcLock = new Object();

    /** System Context for resolving content:// image URIs off the clipboard. Null if the OEM
     *  build wouldn't let us build one — then image capture is skipped and text still works. */
    static volatile Context appContext;
    /** Hard ceiling on a captured image before we base64 it over the localhost socket; the app
     *  re-encodes to fit the relay frame cap, but this stops a pathological multi-MB read. */
    static final int MAX_IMAGE_BYTES = 25 * 1024 * 1024;

    // single connected app client (newest-wins: a fresh authenticated connection evicts the old)
    static volatile OutputStream out;
    static volatile Socket liveClient;
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
        Object local = svc;
        if (local == null) {
            synchronized (svcLock) {
                local = svc;
                if (local == null) {
                    Class<?> sm = Class.forName("android.os.ServiceManager");
                    IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "clipboard");
                    Class<?> stub = Class.forName("android.content.IClipboard$Stub");
                    local = stub.getMethod("asInterface", IBinder.class).invoke(null, b);
                    svc = local;
                }
            }
        }
        return local;
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

    static ClipData readClip() throws Exception {
        Method m = find("getPrimaryClip");
        return (ClipData) m.invoke(svc(), args(m, null, null));
    }

    static CharSequence read() throws Exception {
        ClipData c = readClip();
        return (c == null || c.getItemCount() == 0) ? null : c.getItemAt(0).getText();
    }

    // ---------------------------------------------------------------------
    // clipboard capture (text or image) — the single path both the change
    // listener and the on-connect initial sync go through
    // ---------------------------------------------------------------------

    /**
     * Read the current primary clip and emit it. Text takes priority (a browser image copy often
     * carries a URL string too); an image-only copy falls through to {@link #emitImage}.
     * `initial` = the on-connect sync, which always emits (no lastSeen gate) so a freshly
     * connected app receives whatever is already on the clipboard.
     */
    static void capture(boolean initial) {
        try {
            ClipData c = readClip();
            if (c == null || c.getItemCount() == 0) {
                if (!initial) log("clip changed but empty/unreadable");
                return;
            }
            ClipData.Item item = c.getItemAt(0);
            CharSequence text = item.getText();
            if (text != null) {
                String s = text.toString();
                if (initial) {
                    lastSeen = s;
                    emitClip(s);
                } else if (!s.equals(lastSeen)) {
                    lastSeen = s;
                    log("captured -> emit");
                    emitClip(s);
                }
                return;
            }
            Uri uri = item.getUri();
            if (uri == null) {
                if (!initial) log("clip changed, no text or uri");
                return;
            }
            // Cheap type check off the clip's own description — no ContentResolver call.
            android.content.ClipDescription desc = c.getDescription();
            if (desc == null || !desc.hasMimeType("image/*")) {
                if (!initial) log("clip uri is not an image");
                return;
            }
            // Our own Mac→phone image just written to the clipboard — don't read + echo it back.
            String auth = uri.getAuthority();
            if (auth != null && auth.endsWith(".selfadb.fileprovider")) {
                return;
            }
            emitImage(uri, initial);
        } catch (Exception e) {
            log("capture error: " + e.getMessage());
        }
    }

    /** Resolve a clipboard image URI to bytes and emit them base64. Non-fatal on any failure. */
    static void emitImage(Uri uri, boolean initial) {
        try {
            String key = uri.toString();
            if (!initial && key.equals(lastImageKey)) return; // same image already emitted
            byte[] bytes = readViaExternalProvider(uri);
            if (bytes == null || bytes.length == 0) { log("image read empty/unreadable"); return; }
            if (bytes.length > MAX_IMAGE_BYTES) { log("image too large (" + bytes.length + " B), skipped"); return; }
            String mime = sniffMime(bytes); // magic bytes — accurate, no resolver getType() call
            lastImageKey = key;
            JSONObject o = new JSONObject();
            o.put("type", "image");
            o.put("mime", mime);
            o.put("data", Base64.encodeToString(bytes, Base64.NO_WRAP));
            o.put("ts", System.currentTimeMillis());
            send(o);
            log("captured image -> emit (" + mime + ", " + bytes.length + " B)");
        } catch (Exception e) {
            // A SecurityException here = the shell resolver wasn't granted this URI (some
            // provider-private images). Non-fatal: just skip that image.
            log("image capture failed: " + e.getMessage());
        }
    }

    /**
     * Read a content:// URI as shell WITHOUT being a registered app. The normal ContentResolver
     * path asks AMS to hand the provider to our app process, which fails ("Unable to find app for
     * caller …") because our ActivityThread was never registered via attach(). Instead we use the
     * same mechanism the `adb shell content` command uses: `getContentProviderExternal` acquires
     * the provider against a bare token, then we `openFile` it with our shell AttributionSource and
     * release it. All reflective — these are hidden framework APIs.
     */
    static byte[] readViaExternalProvider(Uri uri) throws Exception {
        String authority = uri.getAuthority();
        if (authority == null) throw new Exception("uri has no authority");

        Class<?> amCls = Class.forName("android.app.ActivityManager");
        Object am = amCls.getMethod("getService").invoke(null); // IActivityManager
        Class<?> iamCls = Class.forName("android.app.IActivityManager");

        IBinder token = new Binder();
        // userId = uid / PER_USER_RANGE (UserHandle.getUserId is hidden); shell on the primary user -> 0.
        int userId = android.os.Process.myUid() / 100000;

        Method getExt = iamCls.getMethod(
                "getContentProviderExternal", String.class, int.class, IBinder.class, String.class);
        Object holder = getExt.invoke(am, authority, userId, token, "clip-image");
        if (holder == null) throw new Exception("no provider for " + authority);

        Method remExt = iamCls.getMethod("removeContentProviderExternal", String.class, IBinder.class);
        try {
            Object provider = Class.forName("android.app.ContentProviderHolder")
                    .getField("provider").get(holder); // IContentProvider
            if (provider == null) throw new Exception("null provider for " + authority);

            Class<?> icpCls = Class.forName("android.content.IContentProvider");
            Class<?> attrCls = Class.forName("android.content.AttributionSource");
            Class<?> cancelCls = Class.forName("android.os.ICancellationSignal");
            Object attr = new android.content.AttributionSource.Builder(android.os.Process.myUid())
                    .setPackageName(PKG).build();

            Method openFile = icpCls.getMethod("openFile", attrCls, Uri.class, String.class, cancelCls);
            Object pfd = openFile.invoke(provider, attr, uri, "r", null);
            if (pfd == null) throw new Exception("openFile returned null");
            return readAll(new android.os.ParcelFileDescriptor.AutoCloseInputStream(
                    (android.os.ParcelFileDescriptor) pfd));
        } finally {
            try {
                remExt.invoke(am, authority, token);
            } catch (Throwable ignored) {
            }
        }
    }

    /** PNG/JPEG from the leading magic bytes; default png. */
    static String sniffMime(byte[] b) {
        if (b.length >= 3 && (b[0] & 0xFF) == 0xFF && (b[1] & 0xFF) == 0xD8 && (b[2] & 0xFF) == 0xFF) {
            return "image/jpeg";
        }
        if (b.length >= 8 && (b[0] & 0xFF) == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
            return "image/png";
        }
        return "image/png";
    }

    static byte[] readAll(InputStream in) throws Exception {
        if (in == null) return null;
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            try { in.close(); } catch (Exception ignored) {}
        }
    }

    /**
     * Build the shell-uid system Context used to resolve clipboard image URIs. **Must run on the
     * main thread**, called once from {@link #main}: `new ActivityThread()` creates an internal
     * `Handler`, which needs a prepared `Looper` on the *current* thread — only the main thread has
     * one (`prepareMainLooper`). Calling this from a worker (clip-client / binder) thread throws
     * "Can't create handler inside thread … that has not called Looper.prepare()". Worker threads
     * therefore only ever *read* the cached result via {@link #context()}.
     *
     * We must NOT call `ActivityThread.systemMain()` (it would re-prepare the main Looper); instead
     * we replicate scrcpy's `Workarounds`: construct a bare `ActivityThread`, publish it as
     * `sCurrentActivityThread`, and give it a minimal `mBoundApplication` whose `appInfo.packageName`
     * is our shell package — `getSystemContext()` reads both and NPEs without them. Leaves
     * `appContext` null (image capture disabled, text still works) if the build refuses.
     */
    static void initContext() {
        try {
            Class<?> atc = Class.forName("android.app.ActivityThread");
            Constructor<?> ctor = atc.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object at = ctor.newInstance();

            // Publish as the process's current ActivityThread — provider acquisition and
            // getSystemContext() read this static on several API levels.
            try {
                Field cur = atc.getDeclaredField("sCurrentActivityThread");
                cur.setAccessible(true);
                cur.set(null, at);
            } catch (Throwable ignored) {
            }

            // Minimal AppBindData{ appInfo.packageName = "com.android.shell" } so getSystemContext()'s
            // ContextImpl/LoadedApk setup doesn't dereference null.
            try {
                Class<?> abd = Class.forName("android.app.ActivityThread$AppBindData");
                Constructor<?> abdCtor = abd.getDeclaredConstructor();
                abdCtor.setAccessible(true);
                Object bind = abdCtor.newInstance();
                android.content.pm.ApplicationInfo ai = new android.content.pm.ApplicationInfo();
                ai.packageName = PKG;
                Field appInfo = abd.getDeclaredField("appInfo");
                appInfo.setAccessible(true);
                appInfo.set(bind, ai);
                Field mBound = atc.getDeclaredField("mBoundApplication");
                mBound.setAccessible(true);
                mBound.set(at, bind);
            } catch (Throwable ignored) {
            }

            // Android 12+ delegates config to `mConfigurationController` (null after a bare ctor);
            // getSystemContext() calls getConfiguration() through it and NPEs. Build one bound to
            // this ActivityThread and seed it with the real system Configuration.
            try {
                Class<?> ccc = Class.forName("android.app.ConfigurationController");
                Class<?> ati = Class.forName("android.app.ActivityThreadInternal");
                Constructor<?> ccCtor = ccc.getDeclaredConstructor(ati);
                ccCtor.setAccessible(true);
                Object cc = ccCtor.newInstance(at);
                try {
                    Field cfg = ccc.getDeclaredField("mConfiguration");
                    cfg.setAccessible(true);
                    cfg.set(cc, android.content.res.Resources.getSystem().getConfiguration());
                } catch (Throwable ignored) {
                }
                Field ccField = atc.getDeclaredField("mConfigurationController");
                ccField.setAccessible(true);
                ccField.set(at, cc);
            } catch (Throwable ignored) {
            }

            appContext = (Context) atc.getMethod("getSystemContext").invoke(at);

            // getSystemContext() reports package "android" (uid 1000), but we run as shell (uid
            // 2000): ContentResolver then rejects our reads with "calling package android does not
            // match caller's uid 2000". Rewrite the ContextImpl's AttributionSource (API 31+) to
            // our real shell identity so getOpPackageName()/getAttributionSource() match our uid.
            try {
                int uid = android.os.Process.myUid();
                android.content.AttributionSource src =
                        new android.content.AttributionSource.Builder(uid).setPackageName(PKG).build();
                Field asf = appContext.getClass().getDeclaredField("mAttributionSource");
                asf.setAccessible(true);
                asf.set(appContext, src);
                // The resolver caches its package name at construction — refresh it too.
                try {
                    android.content.ContentResolver cr = appContext.getContentResolver();
                    Field pkgf = android.content.ContentResolver.class.getDeclaredField("mPackageName");
                    pkgf.setAccessible(true);
                    pkgf.set(cr, PKG);
                } catch (Throwable ignored) {
                }
                log("attribution -> " + PKG + " (uid " + uid + ")");
            } catch (Throwable t2) {
                log("attribution rewrite failed (image read may fail): " + t2);
            }

            log("system context ready (image capture enabled)");
        } catch (Throwable t) {
            // Unwrap the reflective wrapper so the log shows the real cause.
            Throwable cause = (t instanceof InvocationTargetException && t.getCause() != null)
                    ? t.getCause() : t;
            log("system context unavailable (image capture disabled): " + cause);
        }
    }

    /** The system Context built once on the main thread by {@link #initContext}; null if it
     *  couldn't be built (then image capture is skipped and text sync still works). */
    static Context context() {
        return appContext;
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
                if (!o.has("text")) {
                    log("write ignored (no text field)"); // optString would silently CLEAR the clipboard
                    return;
                }
                String text = o.optString("text");
                write(text);
                lastSeen = text;       // stamp only after a successful write, or a throw
                                       // leaves a stale stamp that mis-suppresses a real copy
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

    /** Local wall-clock HH:mm:ss for a log line. New formatter per call = thread-safe (log() is
     *  called from the main, binder, and client threads); the daemon logs rarely, so it's cheap. */
    static String ts() {
        return new java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
                .format(new java.util.Date());
    }

    static void log(String s) {
        // Stamp each line with the time it was written — the app fetches the whole buffer at once,
        // so only the daemon can know when a given line happened. Matches the app log's HH:mm:ss.
        String line = ts() + "  " + s;
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
        // Callers only reach here with a secret set (legacy open mode skips auth entirely),
        // but an auth check must never NPE the daemon if that ever changes.
        if (secret == null) {
            return false;
        }
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

    /**
     * Accept loop: every inbound connection gets its own handler thread, and a newly
     * AUTHENTICATED connection evicts the previous live one (newest-wins). The old
     * single-threaded design let one stuck authenticated socket block accept() forever —
     * a restarted bridge could never get back in without a daemon restart. A post-auth read
     * timeout is not an option (idle-with-no-clips is normal), so eviction is the fix.
     */
    static void serve(int port, String secret) throws Exception {
        ServerSocket server = new ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"));
        try {
            log("listening 127.0.0.1:" + port + (secret != null ? " (auth required)" : ""));
            while (true) {
                final Socket s = server.accept();
                log("client connected");
                Thread t = new Thread(() -> handleClient(s, secret), "clip-client");
                t.setDaemon(true);
                t.start();
            }
        } finally {
            // A fatal accept error must release the port, or it stays bound (unusable,
            // yet probe()-able as "alive") until the process dies.
            try {
                server.close();
            } catch (Exception ignored) {
            }
        }
    }

    static void handleClient(Socket s, String secret) {
        try {
            BufferedReader r = new BufferedReader(
                    new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
            // Auth gate BEFORE anything is served (no `out`, no initial clip sync). The
            // read timeout stops a silent client from tying up a handler thread.
            if (secret != null) {
                s.setSoTimeout(5000);
                String first = r.readLine();
                if (first == null || !authOk(first, secret)) {
                    log("client rejected (bad or missing auth)");
                    return; // finally closes the socket
                }
                s.setSoTimeout(0);
                log("client authenticated");
            }
            // Newest-wins: become the live client; closing the old socket unblocks its
            // handler's readLine() so that thread unwinds on its own.
            Socket old;
            synchronized (outLock) {
                old = liveClient;
                liveClient = s;
                out = s.getOutputStream();
            }
            if (old != null && old != s) {
                log("replacing previous client");
                try {
                    old.close();
                } catch (Exception ignored) {
                }
            }
            // send current clipboard once on connect (initial sync) — text or image
            capture(true);
            // reader loop for this connection
            String line;
            while ((line = r.readLine()) != null) {
                handleCommand(line);
            }
        } catch (Exception e) {
            log("client read end: " + e.getMessage());
        } finally {
            synchronized (outLock) {
                if (liveClient == s) { // an evicted client must not null the successor's `out`
                    liveClient = null;
                    out = null;
                }
            }
            try {
                s.close();
            } catch (Exception ignored) {
            }
            log("client disconnected");
        }
    }

    // ---------------------------------------------------------------------
    /** Parse the port arg defensively — a malformed value must not kill the daemon pre-bind. */
    static int parsePort(String[] x) {
        if (x.length > 0) {
            try {
                int p = Integer.parseInt(x[0]);
                if (p >= 1 && p <= 65535) {
                    return p;
                }
            } catch (NumberFormatException ignored) {
            }
        }
        return 53123;
    }

    public static void main(String[] x) throws Exception {
        final int port = parsePort(x);
        // Bridge-auth secret (never logged). Absent -> legacy open mode, for a stale launcher.
        final String secret = (x.length > 1 && !x[1].isEmpty()) ? x[1] : null;
        Looper.prepareMainLooper();
        log("server up. uid=" + android.os.Process.myUid() + " port=" + port);

        // Build the system Context HERE, on the main thread — it creates a Handler that needs this
        // thread's prepared Looper. Worker threads (clip-client / binder) only read the cached
        // result. Non-fatal: if it fails, text sync still works and images are skipped.
        initContext();

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
                        capture(false); // text or image; own-write echo handled inside
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
