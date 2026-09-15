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
 * a map: a 64 MB transfer held as chunks *and* then concatenated would need ~128 MB of heap, which
 * is a straightforward OOM on a mid-range phone. `RandomAccessFile` + seek costs one chunk of heap
 * no matter how big the file is, and tolerates out-of-order arrival for free (frames are ordered
 * on a single socket today, but nothing here depends on that).
 *
 * Everything is bounded, because an inbound transfer is peer-controlled: [MAX_CONCURRENT]
 * transfers, [FileFrame.MAX_TRANSFER_BYTES] each, and anything idle past [TTL_MS] is swept on the
 * next frame.
 */
class FileInbox(private val dir: File, private val log: (String) -> Unit) {

  /** A transfer whose last chunk just landed. [file] lives in [dir] and is the caller's to consume
   *  and delete. */
  class Completed(val file: File, val mime: String, val name: String?, val disp: String)

  /** What [accept] did with a chunk. [Rejected] is distinct from [Buffered] on purpose: the caller
   *  drives a progress notification off this, and a rejected transfer has to clear it rather than
   *  leave it stuck on screen forever. */
  sealed class Result {
    class Buffered(val received: Int, val total: Int) : Result()
    class Done(val completed: Completed) : Result()
    object Rejected : Result()
  }

  private class Partial(
    val file: File,
    val mime: String,
    val name: String?,
    val disp: String,
    val count: Int,
  ) {
    val seen = HashSet<Int>()
    var bytes = 0L
    var touched = System.currentTimeMillis()
  }

  private val partials = HashMap<String, Partial>()

  /** Take one decoded data frame: buffer it, complete the transfer, or reject it. */
  @Synchronized
  fun accept(frame: FileFrame): Result {
    sweep()
    val id = frame.id ?: return Result.Rejected
    if (frame.count <= 0 || frame.seq < 0 || frame.seq >= frame.count) {
      log("file: chunk ${frame.seq}/${frame.count} out of range")
      return Result.Rejected
    }

    var partial = partials[id]
    if (partial == null) {
      if (partials.size >= MAX_CONCURRENT) {
        log("file: too many transfers in flight; dropping $id")
        return Result.Rejected
      }
      if (!dir.exists()) dir.mkdirs()
      partial = Partial(File(dir, "in-$id"), frame.mime, frame.name, frame.disp, frame.count)
      partials[id] = partial
    }
    if (partial.count != frame.count) {
      log("file: chunk count changed mid-transfer for $id; dropping")
      discard(id)
      return Result.Rejected
    }

    if (partial.seen.add(frame.seq)) {
      partial.bytes += frame.bytes.size
      if (partial.bytes > FileFrame.MAX_TRANSFER_BYTES) {
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
    }
    partial.touched = System.currentTimeMillis()

    if (partial.seen.size < partial.count) {
      return Result.Buffered(received = partial.seen.size, total = partial.count)
    }
    partials.remove(id)
    return Result.Done(Completed(partial.file, partial.mime, partial.name, partial.disp))
  }

  /** Drop transfers whose sender went away mid-file, so a dead Mac can't leave temp files (or a
   *  map entry) behind forever. */
  private fun sweep() {
    val cutoff = System.currentTimeMillis() - TTL_MS
    partials.entries.toList().forEach { (id, p) ->
      if (p.touched < cutoff) {
        log("file: transfer $id abandoned (${p.seen.size}/${p.count} chunks)")
        discard(id)
      }
    }
  }

  private fun discard(id: String) {
    partials.remove(id)?.file?.delete()
  }

  private companion object {
    const val MAX_CONCURRENT = 2
    const val TTL_MS = 120_000L
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

  /** Copy [source] into Downloads/Link to Mac. Returns the MediaStore URI, or null on failure. */
  fun saveToDownloads(ctx: Context, source: File, name: String?, mime: String): Uri? {
    val resolver = ctx.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, sanitize(name, mime))
      put(MediaStore.Downloads.MIME_TYPE, mime)
      put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Link to Mac")
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
