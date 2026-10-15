package expo.modules.selfadb

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * One row of the Files screen: a file that came in from the Mac or went out to it.
 *
 * `status` is `queued` (waiting its turn in a batch), `active`, `done`, `failed` or `cancelled`.
 * [uri] is where a received file now lives (a MediaStore URI, so it can be opened); [source] is
 * where a sent one came from **when a persisted read grant makes it retryable** (picker sends —
 * a share-sheet URI's grant dies with the activity).
 */
data class HistoryEntry(
  val id: String = UUID.randomUUID().toString(),
  val direction: String, // "in" | "out"
  val name: String,
  val dir: String? = null,
  val size: Long = 0,
  val mime: String = "application/octet-stream",
  val ts: Long,
  val status: String,
  val error: String? = null,
  val progress: Int = 0,
  val uri: String? = null,
  val source: String? = null,
) {
  /** Can the user retry it? Only a send that didn't finish and still has a readable source. */
  val retryable: Boolean get() = direction == "out" && source != null && (status == "failed" || status == "cancelled")

  fun toMap(): Map<String, Any?> = mapOf(
    "id" to id, "direction" to direction, "name" to name, "dir" to dir, "size" to size.toDouble(),
    "mime" to mime, "ts" to ts.toDouble(), "status" to status, "error" to error, "progress" to progress,
    "uri" to uri, "retryable" to retryable,
  )

  fun toJson(): JSONObject = JSONObject()
    .put("id", id).put("direction", direction).put("name", name).put("dir", dir ?: JSONObject.NULL)
    .put("size", size).put("mime", mime).put("ts", ts).put("status", status)
    .put("error", error ?: JSONObject.NULL).put("progress", progress)
    .put("uri", uri ?: JSONObject.NULL).put("source", source ?: JSONObject.NULL)

  companion object {
    fun fromJson(o: JSONObject): HistoryEntry = HistoryEntry(
      id = o.getString("id"),
      direction = o.getString("direction"),
      name = o.getString("name"),
      dir = o.optString("dir").ifEmpty { null }.takeIf { !o.isNull("dir") },
      size = o.optLong("size"),
      mime = o.optString("mime", "application/octet-stream"),
      ts = o.optLong("ts"),
      status = o.getString("status"),
      error = o.optString("error").ifEmpty { null }.takeIf { !o.isNull("error") },
      progress = o.optInt("progress"),
      uri = o.optString("uri").ifEmpty { null }.takeIf { !o.isNull("uri") },
      source = o.optString("source").ifEmpty { null }.takeIf { !o.isNull("source") },
    )
  }
}

/**
 * A bounded, persisted list of [HistoryEntry]s in a JSON file. Plain Kotlin over a `File`, so it is
 * unit-tested without Android; [FileHistory] wraps one in the app's `filesDir`.
 *
 * It lives in the foreground service's process-wide state, not in JS, so it survives the app being
 * swiped away (transfers keep running and keep recording). To keep a fast transfer from rewriting
 * the file on every chunk, only a **status change** is persisted; progress updates stay in memory.
 * An entry still `queued`/`active` when the file is loaded belongs to a process that died, so it is
 * marked `failed` ("Interrupted") rather than shown spinning forever.
 */
class FileHistoryStore(private val file: File, private val max: Int = MAX_ENTRIES) {
  private val entries = ArrayList<HistoryEntry>() // newest first
  private var loaded = false

  @Synchronized
  fun list(): List<HistoryEntry> { ensureLoaded(); return entries.toList() }

  @Synchronized
  fun find(id: String): HistoryEntry? { ensureLoaded(); return entries.firstOrNull { it.id == id } }

  /** Insert or replace by id (a new entry goes on top). [persist] false for a progress tick. */
  @Synchronized
  fun upsert(entry: HistoryEntry, persist: Boolean = true): HistoryEntry {
    ensureLoaded()
    val at = entries.indexOfFirst { it.id == entry.id }
    if (at >= 0) entries[at] = entry else entries.add(0, entry)
    while (entries.size > max) entries.removeAt(entries.size - 1)
    if (persist) save()
    return entry
  }

  @Synchronized
  fun clear() { ensureLoaded(); entries.clear(); save() }

  private fun ensureLoaded() {
    if (loaded) return
    loaded = true
    try {
      if (!file.exists()) return
      val arr = JSONArray(file.readText())
      for (i in 0 until arr.length()) {
        val e = HistoryEntry.fromJson(arr.getJSONObject(i))
        entries += if (e.status == "queued" || e.status == "active") e.copy(status = "failed", error = "Interrupted") else e
      }
    } catch (e: Exception) {
      // A corrupt file shouldn't take the Files screen down with it: start over.
      entries.clear()
    }
  }

  private fun save() {
    try {
      val arr = JSONArray()
      entries.forEach { arr.put(it.toJson()) }
      val tmp = File(file.parentFile, file.name + ".tmp")
      tmp.writeText(arr.toString())
      if (!tmp.renameTo(file)) { file.writeText(arr.toString()); tmp.delete() }
    } catch (e: Exception) {
      // History is a convenience; never let a full disk break a transfer.
    }
  }

  companion object {
    const val MAX_ENTRIES = 200
  }
}

/** The app-wide history, backed by `filesDir/file-history.json`; emits every change to the JS side. */
object FileHistory {
  @Volatile private var store: FileHistoryStore? = null

  private fun store(ctx: Context): FileHistoryStore =
    store ?: synchronized(this) {
      store ?: FileHistoryStore(File(ctx.applicationContext.filesDir, "file-history.json")).also { store = it }
    }

  fun list(ctx: Context): List<HistoryEntry> = store(ctx).list()

  fun find(ctx: Context, id: String): HistoryEntry? = store(ctx).find(id)

  fun clear(ctx: Context) { store(ctx).clear() }

  /** Record a change and tell the UI. Returns what was stored. */
  fun record(ctx: Context, entry: HistoryEntry, persist: Boolean = true): HistoryEntry {
    val saved = store(ctx).upsert(entry, persist)
    ClipBus.onFileTransfer?.invoke(saved.toMap())
    return saved
  }
}
