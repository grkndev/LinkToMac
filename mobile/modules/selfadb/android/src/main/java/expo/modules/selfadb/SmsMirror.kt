package expo.modules.selfadb

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.LruCache
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

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
 */
class SmsMirror(
  context: Context,
  /** Forwards one ready-to-send `sms` payload JSON (→ [ClipForegroundService.sendSms]). */
  private val send: (String) -> Unit,
  private val log: (String) -> Unit,
) {
  private val resolver = context.applicationContext.contentResolver

  /** Heavy work (provider queries, contact lookups, JSON build) off the observer/caller thread. */
  private val worker = Executors.newSingleThreadExecutor()

  /** Contact display names keyed by address, resolved once per number (PhoneLookup isn't free).
   *  Negative lookups are cached as "" so we don't re-query numbers with no contact. */
  private val nameCache = LruCache<String, String>(256)

  /** Highest `_id` already forwarded, so the observer only sends new rows. -1 until first baseline. */
  @Volatile private var lastMaxId: Long = -1

  private var observerThread: HandlerThread? = null
  private var observer: ContentObserver? = null

  private data class Row(
    val id: Long, val thread: Long, val addr: String, val body: String,
    val date: Long, val dir: String, val read: Boolean,
  )

  fun start() {
    if (observer != null) return
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

  /** Push the most recent [BACKFILL_LIMIT] messages as `op:"batch"` chunks (newest-first). */
  fun backfill() {
    worker.execute {
      val rows = query(null, null, "${Telephony.Sms.DATE} DESC LIMIT $BACKFILL_LIMIT")
      if (rows.isEmpty()) { log("sms backfill: none"); return@execute }
      lastMaxId = maxOf(lastMaxId, rows.maxOf { it.id })
      rows.chunked(CHUNK).forEach { emit("batch", it) }
      log("sms backfill: ${rows.size} msgs")
    }
  }

  /** Query rows newer than [lastMaxId] and push them as an `op:"add"` delta. */
  private fun pushNew() {
    worker.execute {
      if (lastMaxId < 0) {
        // No baseline yet (observer fired before the first backfill). Set one without emitting;
        // the peer-online backfill sends the full recent history.
        val newest = query(null, null, "${Telephony.Sms._ID} DESC LIMIT 1")
        if (newest.isNotEmpty()) lastMaxId = newest.first().id
        return@execute
      }
      val rows = query("${Telephony.Sms._ID} > ?", arrayOf(lastMaxId.toString()), "${Telephony.Sms._ID} ASC")
      if (rows.isEmpty()) return@execute
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
