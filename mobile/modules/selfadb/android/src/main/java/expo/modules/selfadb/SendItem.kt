package expo.modules.selfadb

import android.net.Uri
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * One file on its way to the Mac: where its bytes come from, and enough about it to name the
 * transfer. Built from a staged copy in our cache (a small share-sheet file), straight from a
 * content URI (a large one, or anything picked in the app — no cache copy, so a 1 GB file doesn't
 * need 1 GB of free space), or from a folder walk.
 */
class SendItem(
  val name: String,
  val mime: String,
  /** Folder the file sits in, relative to the root the user picked (`Photos/2024`); null for a loose file. */
  val dir: String?,
  val size: Long,
  /** Last-modified time in seconds, 0 when the provider doesn't say. Part of the transfer's identity. */
  val mtime: Long,
  /** Opens a FRESH stream over the bytes — called once per attempt, and the stream is closed by the caller. */
  val open: () -> InputStream,
  /** A staged copy to delete when the send ends, however it ends. */
  val staged: File? = null,
  /** The content URI this came from, when a persisted read grant makes it retryable later. */
  val source: String? = null,
) {
  /** Chunks the file splits into (a zero-byte file still has none to send; callers reject it first). */
  val chunkCount: Int
    get() = ((size + FileFrame.CHUNK_RAW_BYTES - 1) / FileFrame.CHUNK_RAW_BYTES).toInt().coerceAtLeast(1)

  /** See [TransferId.of]. */
  val transferId: String get() = TransferId.of(name, size, mtime, dir)
}

/**
 * The id a transfer travels under. **Deterministic**, so sending the same file again reuses it —
 * which is how the Mac recognises a retry and reports what it already holds (`have`), letting the
 * sender skip those chunks. The key is name, size, modification time and folder: an edited file
 * changes size or mtime and so starts fresh (an edit that preserves both can't be told apart).
 * Mirrors the Mac's `FileSender.transferID`.
 */
object TransferId {
  fun of(name: String, size: Long, mtime: Long, dir: String?): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$name|$size|$mtime|${dir ?: ""}".toByteArray(Charsets.UTF_8))
    return digest.take(4).joinToString("") { "%02x".format(it) }
  }
}

/** Read and discard exactly [n] bytes (or until the stream ends); `InputStream.skip` may skip less. */
fun InputStream.skipFully(n: Long): Long {
  var left = n
  val scratch = ByteArray(64 * 1024)
  while (left > 0) {
    val skipped = skip(left)
    if (skipped > 0) {
      left -= skipped
    } else {
      // skip() can return 0 on some streams; fall back to reading, and stop at EOF.
      val r = read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
      if (r < 0) break
      left -= r
    }
  }
  return n - left
}

/** One shared file, as [ShareActivity] describes it to the service. */
class ShareRef(
  /** A copy already staged in our cache, or empty when the service should stream [uri] itself. */
  val path: String,
  val uri: Uri,
  val name: String,
  val mime: String,
  val size: Long,
)
