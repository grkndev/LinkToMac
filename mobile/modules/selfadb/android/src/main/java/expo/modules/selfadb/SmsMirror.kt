package expo.modules.selfadb

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.LruCache
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

/**
 * Reads this phone's SMS store and forwards it to the Mac over the E2E `sms` channel, so the Mac
 * dashboard's Messages tab can show real conversation threads. FGS-owned (NOT a system service): it
 * lives in [ClipForegroundService] so the read + the live observer survive the app being swiped
 * away, just like [NotificationListener].
 *
 * The caller checks the READ_SMS/READ_CONTACTS runtime grant + the forwarding toggle before
 * constructing this; here we just read. Two paths:
 *   - [backfill]: query the most recent [BACKFILL_LIMIT] messages and push them as `op:"batch"`
 *     chunks. Run on every peer-online edge so a (re)connecting Mac re-receives the history (the Mac
 *     store is in-memory). Idempotent — the Mac upserts by `id`.
 *   - [start]/[stop]: a [ContentObserver] on `content://sms` that, on any change, queries rows newer
 *     than the last-seen `_id` and pushes them as an `op:"add"` delta (covers received *and* sent).
 *
 * Wire payload (plaintext, then E2E-encrypted by the active link):
 *   { "op":"batch"|"add", "msgs":[ { "id":N, "thread":N, "addr":…, "name":…, "body":…,
 *     "date":<epoch ms>, "dir":"in"|"out", "read":bool }, … ] }
 *
 * [sendReply] is the reverse direction (Mac → phone → real SMS): given a Mac `{"op":"send",…}`
 * request, it sends via [SmsManager] and reports back through [send] (the same outbound channel
 * mirrored messages use) as `{"op":"sent","corr":…,"id":N?}` or
 * `{"op":"failed","corr":…,"error":…}`. We are not the default SMS app, so the OS generally
 * won't let us write the sent message into the SMS store ourselves — [sendReply] best-effort
 * inserts one (so it shows up mirrored like any other sent text) but degrades gracefully (`id`
 * omitted) if the OS/OEM refuses the write; the Mac keeps its own optimistic placeholder then.
 */
class SmsMirror(
  context: Context,
  /** Forwards one ready-to-send `sms` payload JSON (→ [ClipForegroundService.sendSms]). */
  private val send: (String) -> Unit,
  private val log: (String) -> Unit,
  /** Called (in addition to the "failed"/"permission" ack) the first time [sendReply] is
   *  blocked by a missing SEND_SMS grant, so the caller can surface a "grant access" prompt —
   *  requesting a dangerous permission needs an Activity, which this background class doesn't have. */
  private val onSendPermissionDenied: () -> Unit = {},
) {
  private val appContext = context.applicationContext
  private val resolver = appContext.contentResolver

  /** Heavy work (provider queries, contact lookups, JSON build) off the observer/caller thread.
   *  Recreated by [start] after a [stop] — callers happen to reconstruct the whole object today,
   *  but a reused instance must not silently drop work on a dead executor. */
  private var worker = Executors.newSingleThreadExecutor()

  /** Contact display names keyed by address, resolved once per number (PhoneLookup isn't free).
   *  Negative lookups are cached as "" so we don't re-query numbers with no contact. */
  private val nameCache = LruCache<String, String>(256)

  /** Highest `_id` already forwarded, so the observer only sends new rows. -1 until first baseline. */
  @Volatile private var lastMaxId: Long = -1

  /** Monotonic base for sent-intent `PendingIntent` request codes, so concurrent [sendReply]
   *  calls (and their possibly-multipart sent intents) never collide with FLAG_UPDATE_CURRENT. */
  private val nextReqCode = AtomicInteger(0)

  private var observerThread: HandlerThread? = null
  private var observer: ContentObserver? = null

  private data class Row(
    val id: Long, val thread: Long, val addr: String, val body: String,
    val date: Long, val dir: String, val read: Boolean,
  )

  fun start() {
    if (observer != null) return
    if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
    val thread = HandlerThread("sms-observer").also { it.start() }
    observerThread = thread
    val obs = object : ContentObserver(Handler(thread.looper)) {
      override fun onChange(selfChange: Boolean) = pushNew()
    }
    observer = obs
    try {
      resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, obs)
      log("sms observer registered")
    } catch (e: Exception) {
      log("sms observer register failed: ${e.message}")
    }
  }

  fun stop() {
    observer?.let { try { resolver.unregisterContentObserver(it) } catch (e: Exception) {} }
    observer = null
    observerThread?.quitSafely()
    observerThread = null
    worker.shutdown()
  }

  /** Send [body] to [addr] as a real SMS via [SmsManager], reporting the result back through
   *  [send] as an ack keyed by the Mac's [corr]. Checked/dispatched synchronously (permission
   *  check + `sendMultipartTextMessage` are cheap/async themselves); the ack arrives later via
   *  the sent-intent [BroadcastReceiver] once the radio confirms (or fails) the send. */
  fun sendReply(addr: String, body: String, corr: String) {
    if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
      send(ackJson("failed", corr, error = "permission"))
      onSendPermissionDenied()
      log("sms reply: SEND_SMS not granted")
      return
    }
    post {
      try {
        val smsManager = SmsManager.getDefault()
        val parts = smsManager.divideMessage(body)
        val reqBase = nextReqCode.getAndAdd(parts.size)
        val pendingCount = AtomicInteger(parts.size)
        val anyFailed = java.util.concurrent.atomic.AtomicBoolean(false)
        val action = "expo.modules.selfadb.SMS_REPLY_SENT.$reqBase"
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val sentIntents = ArrayList<PendingIntent>(parts.size)
        for (i in parts.indices) {
          val intent = Intent(action).setPackage(appContext.packageName)
          sentIntents.add(PendingIntent.getBroadcast(appContext, reqBase + i, intent, flags))
        }
        val receiver = object : BroadcastReceiver() {
          override fun onReceive(ctx: Context, intent: Intent) {
            if (resultCode != Activity.RESULT_OK) anyFailed.set(true)
            if (pendingCount.decrementAndGet() == 0) {
              try { appContext.unregisterReceiver(this) } catch (e: Exception) {}
              if (anyFailed.get()) {
                send(ackJson("failed", corr, error = "send-error"))
                log("sms reply failed ($corr)")
              } else {
                val id = tryInsertSent(addr, body)
                send(ackJson("sent", corr, id = id))
                log("sms reply sent ($corr)" + (id?.let { " id=$it" } ?: " (no store id)"))
              }
            }
          }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
          @Suppress("UnspecifiedRegisterReceiverFlag")
          appContext.registerReceiver(receiver, filter)
        }
        smsManager.sendMultipartTextMessage(addr, null, parts, sentIntents, null)
      } catch (e: Exception) {
        log("sms reply send threw: ${e.message}")
        send(ackJson("failed", corr, error = "send-error"))
      }
    }
  }

  /** Best-effort insert of the just-sent message into the SMS store so it mirrors like any other
   *  sent text. Returns the new row id, or null if the OS/OEM refused the write — expected on
   *  most devices since we're not the default SMS app, not a bug. */
  private fun tryInsertSent(addr: String, body: String): Long? {
    return try {
      val threadId = Telephony.Threads.getOrCreateThreadId(appContext, addr)
      val values = ContentValues().apply {
        put(Telephony.Sms.ADDRESS, addr)
        put(Telephony.Sms.BODY, body)
        put(Telephony.Sms.DATE, System.currentTimeMillis())
        put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
        put(Telephony.Sms.READ, 1)
        put(Telephony.Sms.THREAD_ID, threadId)
      }
      resolver.insert(Telephony.Sms.CONTENT_URI, values)?.lastPathSegment?.toLongOrNull()
    } catch (e: Exception) {
      null
    }
  }

  private fun ackJson(op: String, corr: String, id: Long? = null, error: String? = null): String {
    val o = JSONObject().put("op", op).put("corr", corr)
    id?.let { o.put("id", it) }
    error?.let { o.put("error", it) }
    return o.toString()
  }

  /** Run on the worker, dropping the task if [stop] already shut it down (a late observer
   *  callback racing stop() must not crash the observer thread). */
  private fun post(task: Runnable) {
    try {
      worker.execute(task)
    } catch (e: RejectedExecutionException) {
      // stopped; late work intentionally dropped
    }
  }

  /** Push the most recent [BACKFILL_LIMIT] messages as `op:"batch"` chunks (newest-first). */
  fun backfill() {
    post {
      val rows = query(null, null, "${Telephony.Sms.DATE} DESC LIMIT $BACKFILL_LIMIT")
      if (rows.isEmpty()) { log("sms backfill: none"); return@post }
      lastMaxId = maxOf(lastMaxId, rows.maxOf { it.id })
      rows.chunked(CHUNK).forEach { emit("batch", it) }
      log("sms backfill: ${rows.size} msgs")
    }
  }

  /** Query rows newer than [lastMaxId] and push them as an `op:"add"` delta. */
  private fun pushNew() {
    post {
      if (lastMaxId < 0) {
        // No baseline yet (observer fired before the first backfill). Set one without emitting;
        // the peer-online backfill sends the full recent history.
        val newest = query(null, null, "${Telephony.Sms._ID} DESC LIMIT 1")
        if (newest.isNotEmpty()) lastMaxId = newest.first().id
        return@post
      }
      val rows = query("${Telephony.Sms._ID} > ?", arrayOf(lastMaxId.toString()), "${Telephony.Sms._ID} ASC")
      if (rows.isEmpty()) return@post
      lastMaxId = maxOf(lastMaxId, rows.maxOf { it.id })
      rows.chunked(CHUNK).forEach { emit("add", it) }
      log("sms delta: ${rows.size} new")
    }
  }

  private fun emit(op: String, rows: List<Row>) {
    if (rows.isEmpty()) return
    val arr = JSONArray()
    for (r in rows) {
      val o = JSONObject()
        .put("id", r.id)
        .put("thread", r.thread)
        .put("addr", r.addr)
        .put("body", r.body)
        .put("date", r.date)
        .put("dir", r.dir)
        .put("read", r.read)
      contactName(r.addr)?.let { o.put("name", it) }
      arr.put(o)
    }
    send(JSONObject().put("op", op).put("msgs", arr).toString())
  }

  private fun query(selection: String?, selectionArgs: Array<String>?, sortOrder: String?): List<Row> {
    val cols = arrayOf(
      Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
      Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ,
    )
    val out = ArrayList<Row>()
    try {
      resolver.query(Telephony.Sms.CONTENT_URI, cols, selection, selectionArgs, sortOrder)?.use { c ->
        val iId = c.getColumnIndexOrThrow(Telephony.Sms._ID)
        val iThread = c.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
        val iAddr = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
        val iBody = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
        val iDate = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
        val iType = c.getColumnIndexOrThrow(Telephony.Sms.TYPE)
        val iRead = c.getColumnIndexOrThrow(Telephony.Sms.READ)
        while (c.moveToNext()) {
          val type = c.getInt(iType)
          // Only real conversation traffic: DRAFT(3)/OUTBOX(4)/FAILED(5)/QUEUED(6) would
          // otherwise render on the Mac as sent messages the user never sent.
          if (type != Telephony.Sms.MESSAGE_TYPE_INBOX && type != Telephony.Sms.MESSAGE_TYPE_SENT) continue
          out.add(
            Row(
              id = c.getLong(iId),
              thread = c.getLong(iThread),
              addr = c.getString(iAddr) ?: "",
              body = c.getString(iBody) ?: "",
              date = c.getLong(iDate),
              dir = if (type == Telephony.Sms.MESSAGE_TYPE_INBOX) "in" else "out",
              read = c.getInt(iRead) != 0,
            )
          )
        }
      }
    } catch (e: Exception) {
      log("sms query failed: ${e.message}")
    }
    return out
  }

  /** Contact display name for [addr] via PhoneLookup, memoized (incl. negative results). Null when
   *  there's no contact or READ_CONTACTS is missing — the Mac then falls back to the raw address. */
  private fun contactName(addr: String): String? {
    if (addr.isEmpty()) return null
    nameCache.get(addr)?.let { return it.ifEmpty { null } }
    var name: String? = null
    try {
      val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(addr))
      resolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) name = c.getString(0)
      }
    } catch (e: Exception) {
      // READ_CONTACTS may be absent even if READ_SMS was granted — degrade to the number.
    }
    nameCache.put(addr, name ?: "")
    return name
  }

  private companion object {
    const val BACKFILL_LIMIT = 200
    const val CHUNK = 50
  }
}
