package expo.modules.selfadb

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.RandomAccessFile

/**
 * Reassembles chunked inbound `file` transfers (the Mac's "send this to my phone").
 *
 * Chunks are written straight into a temp file at `seq * CHUNK_RAW_BYTES` rather than buffered in
 * a map: a transfer held as chunks *and* then concatenated would need twice its size in heap,
 * which is a straightforward OOM on a mid-range phone. `RandomAccessFile` + seek costs one chunk
 * of heap no matter how big the file is, and tolerates out-of-order arrival for free. (The Mac's
 * `FileInbox` does the same, and is what let the cap rise from 64 MB to 1 GiB.)
 *
 * Everything is bounded, because an inbound transfer is peer-controlled: [MAX_CONCURRENT]
 * transfers, [FileFrame.MAX_TRANSFER_BYTES] each. A half-received transfer is **kept for
 * [TTL_MS]** (10 min) so a retry of the same file can resume — the ack reports how many leading
 * chunks are already here (`have`) — but when every slot is taken, one idle longer than
 * [STALE_MS] is evicted rather than blocking a new transfer.
 */
class FileInbox(
  private val dir: File,
  /** Idle time after which a half-received transfer is swept. A parameter only so a test needn't wait ten minutes. */
  private val ttlMs: Long = TTL_MS,
  /** Idle time after which a partial may be evicted to make room. */
  private val staleMs: Long = STALE_MS,
  /** Per-transfer size cap; a parameter only so a test needn't allocate a gigabyte. */
  private val maxBytes: Long = FileFrame.MAX_TRANSFER_BYTES.toLong(),
  private val log: (String) -> Unit,
) {

  /** A transfer whose last chunk just landed. [file] lives in [dir] and is the caller's to consume
   *  and delete. */
  class Completed(val file: File, val mime: String, val name: String?, val dir: String?, val disp: String)

  /** What [accept] did with a chunk. [Rejected] is distinct from [Buffered] on purpose: the caller
   *  drives a progress notification off this, and a rejected transfer has to clear it rather than
   *  leave it stuck on screen forever. */
  sealed class Result {
    /** [have] = leading chunks `[0, have)` already stored, for the ack (resume). */
    class Buffered(val received: Int, val total: Int, val have: Int) : Result()
    class Done(val completed: Completed) : Result()
    object Rejected : Result()
  }

  private class Partial(
    val file: File,
    val mime: String,
    val name: String?,
    val dir: String?,
    val disp: String,
    val count: Int,
  ) {
    val seen = HashSet<Int>()
    /** Length of the contiguous run `0 until contiguous` — what resume reports as `have`. */
    var contiguous = 0
    /** Frames that arrived for a chunk already stored — what a retry re-sends instead of skipping. */
    var resent = 0
    var bytes = 0L
    var touched = System.currentTimeMillis()
  }

  private val partials = HashMap<String, Partial>()

  init {
    purge(olderThanMs = 60 * 60 * 1000L) // what a process death mid-transfer left behind
  }

  /** Take one decoded data frame: buffer it, complete the transfer, or reject it. */
  @Synchronized
  fun accept(frame: FileFrame): Result {
    sweep()
    val id = frame.id ?: return Result.Rejected
    if (frame.count <= 0 || frame.seq < 0 || frame.seq >= frame.count) {
      log("file: chunk ${frame.seq}/${frame.count} out of range")
      return Result.Rejected
    }
    // A chunk is written at seq * CHUNK_RAW_BYTES; a longer one would overwrite its neighbour.
    if (frame.bytes.size > FileFrame.CHUNK_RAW_BYTES) {
      log("file: chunk of ${frame.bytes.size} B exceeds the chunk size; dropping $id")
      discard(id)
      return Result.Rejected
    }

    var partial = partials[id]
    if (partial == null) {
      if (partials.size >= MAX_CONCURRENT && !evictOldestStale()) {
        log("file: too many transfers in flight; dropping $id")
        return Result.Rejected
      }
      if (!dir.exists()) dir.mkdirs()
      // The id is peer-supplied: keep it to filename-safe characters so it can't traverse out of [dir].
      val safe = id.map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }.joinToString("").take(64)
      partial = Partial(File(dir, "in-$safe"), frame.mime, frame.name, frame.dir, frame.disp, frame.count)
      partials[id] = partial
    }
    if (partial.count != frame.count) {
      log("file: chunk count changed mid-transfer for $id; dropping")
      discard(id)
      return Result.Rejected
    }

    if (!partial.seen.add(frame.seq)) partial.resent++ else {
      partial.bytes += frame.bytes.size
      if (partial.bytes > maxBytes) {
        log("file: transfer $id exceeded the size cap; dropping")
        discard(id)
        return Result.Rejected
      }
      try {
        RandomAccessFile(partial.file, "rw").use { raf ->
          raf.seek(frame.seq.toLong() * FileFrame.CHUNK_RAW_BYTES)
          raf.write(frame.bytes)
        }
      } catch (e: Exception) {
        log("file: couldn't write chunk ${frame.seq} of $id: ${e.message}")
        discard(id)
        return Result.Rejected
      }
      while (partial.seen.contains(partial.contiguous)) partial.contiguous++
    }
    partial.touched = System.currentTimeMillis()

    if (partial.seen.size < partial.count) {
      return Result.Buffered(received = partial.seen.size, total = partial.count, have = partial.contiguous)
    }
    partials.remove(id)
    // How many chunks arrived twice: a resumed transfer re-sends only the few that were in flight when
    // it stopped, a retry that couldn't resume re-sends everything it had already delivered.
    log("file: $id complete — ${partial.count} chunks, ${partial.resent} re-sent")
    return Result.Done(Completed(partial.file, partial.mime, partial.name, partial.dir, partial.disp))
  }

  /** Drop transfers whose sender went away for good (idle past [ttlMs]), so a dead Mac can't leave
   *  temp files (or a map entry) behind forever. */
  private fun sweep() {
    val cutoff = System.currentTimeMillis() - ttlMs
    partials.entries.toList().forEach { (id, p) ->
      if (p.touched < cutoff) {
        log("file: transfer $id abandoned (${p.seen.size}/${p.count} chunks)")
        discard(id)
      }
    }
  }

  /** Free a slot by dropping the partial quiet for longest — but only one quiet for [staleMs]; a
   *  live transfer is never evicted. True if one was freed. */
  private fun evictOldestStale(): Boolean {
    val cutoff = System.currentTimeMillis() - staleMs
    val victim = partials.entries.filter { it.value.touched < cutoff }.minByOrNull { it.value.touched } ?: return false
    log("file: evicting idle transfer ${victim.key} to make room")
    discard(victim.key)
    return true
  }

  private fun discard(id: String) {
    partials.remove(id)?.file?.delete()
  }

  /** Delete temp files older than [olderThanMs]. */
  private fun purge(olderThanMs: Long) {
    val cutoff = System.currentTimeMillis() - olderThanMs
    dir.listFiles()?.filter { it.isFile && it.lastModified() < cutoff }?.forEach { it.delete() }
  }

  private companion object {
    const val MAX_CONCURRENT = 2
    const val TTL_MS = 10 * 60 * 1000L
    const val STALE_MS = 120_000L
  }
}

/**
 * Writes a received file into the phone's shared Downloads, under a "Link to Mac" subfolder.
 *
 * `MediaStore.Downloads` is the right home on API 29+: it needs **no runtime permission**, the
 * file shows up in Files / My Files like any other download, and the store resolves name clashes
 * itself (`photo.jpg` → `photo (1).jpg`). Writing to `Environment.getExternalStoragePublicDirectory`
 * instead would need `WRITE_EXTERNAL_STORAGE`, which stops working at API 29 anyway.
 *
 * `IS_PENDING` brackets the write so nothing indexes or opens a half-written file.
 */
object FileSink {

  /** Copy [source] into Downloads/Link to Mac[/[dir]]. Returns the MediaStore URI, or null on
   *  failure. [dir] is the relative folder a dropped folder's file sat in; it is untrusted. */
  fun saveToDownloads(ctx: Context, source: File, name: String?, mime: String, dir: String? = null): Uri? {
    val resolver = ctx.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, sanitize(name, mime))
      put(MediaStore.Downloads.MIME_TYPE, mime)
      put(MediaStore.Downloads.RELATIVE_PATH, relativePath(dir))
      put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val uri = try {
      resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
    } catch (e: Exception) {
      ClipBus.log("file: MediaStore insert failed: ${e.message}")
      null
    } ?: return null

    return try {
      resolver.openOutputStream(uri)?.use { out ->
        source.inputStream().use { it.copyTo(out) }
      } ?: throw IllegalStateException("no output stream")
      values.clear()
      values.put(MediaStore.Downloads.IS_PENDING, 0)
      resolver.update(uri, values, null, null)
      uri
    } catch (e: Exception) {
      ClipBus.log("file: write to Downloads failed: ${e.message}")
      runCatching { resolver.delete(uri, null, null) } // don't leave a pending stub behind
      null
    }
  }

  /** `Download/Link to Mac` plus the sanitised [dir], when there is one. */
  fun relativePath(dir: String?): String {
    val base = "${Environment.DIRECTORY_DOWNLOADS}/Link to Mac"
    val clean = sanitizeDir(dir)
    return if (clean.isEmpty()) base else "$base/$clean"
  }

  /** A folder path off the wire is untrusted like a name: keep only plain components. Drops
   *  empty, `.` and `..` parts (no traversal out of Link to Mac), strips separators and `:`,
   *  and bounds depth and length so a hostile peer can't build a pathological tree. */
  fun sanitizeDir(dir: String?): String =
    (dir ?: "")
      .split('/', '\\')
      .map { it.replace(":", "-").trim().trim('.').take(MAX_DIR_PART) }
      .filter { it.isNotEmpty() }
      .take(MAX_DIR_DEPTH)
      .joinToString("/")

  private const val MAX_DIR_DEPTH = 8
  private const val MAX_DIR_PART = 100

  /** The name arrives over the wire, so treat it as untrusted: last path component only (no
   *  traversal), no separators, and a timestamped fallback when nothing usable is left. */
  fun sanitize(name: String?, mime: String): String {
    val cleaned = (name ?: "")
      .substringAfterLast('/')
      .substringAfterLast('\\')
      .replace(":", "-")
      .trim()
      .trim('.')
    if (cleaned.isNotEmpty()) return cleaned
    val ext = when {
      mime == "image/jpeg" -> "jpg"
      mime.startsWith("image/") -> mime.substringAfter('/')
      mime == "application/pdf" -> "pdf"
      else -> "bin"
    }
    return "mac-${System.currentTimeMillis()}.$ext"
  }
}
