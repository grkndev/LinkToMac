package expo.modules.selfadb

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File
import java.util.UUID

/**
 * Our two entries in the system share sheet. Share a photo from Gallery (or anything from any
 * app), pick "Send to Clipboard" or "Send as a File", and it goes straight to the Mac with no
 * app UI — the same fire-and-forget shape as [ProcessTextActivity].
 *
 * Unlike that one it runs under `Theme.LinkToMac.Invisible` rather than `Theme.NoDisplay`: a
 * NoDisplay activity must finish inside `onCreate`, and this one has to outlive a worker thread
 * (see below). The Invisible theme is a real window that paints and animates nothing, so the
 * user still never sees anything.
 *
 * **Why two activities and not one activity that asks.** The share sheet is built by the system
 * before this process is ever involved, and targets are matched on `action` + `mimeType` only —
 * the payload's size is never consulted, and the one API that could vary targets at runtime
 * (`ChooserTargetService`) was deprecated in API 30 and is not called at all on API 31+. So a
 * "hide the clipboard option for big files" sheet is not expressible. It is also unnecessary:
 * clipboard sends are downscaled to fit ([ClipForegroundService.fitImage] — the right behaviour
 * for something you are going to paste) and file sends are chunked ([FileFrame.CHUNK_RAW_BYTES]),
 * so **both work at any size**. The choice is what the file is for, not how big it is, and the
 * mime filters in the manifest express the only real constraint: clipboard takes images, file
 * takes anything.
 *
 * The URI read grant that rides in on the share intent is scoped to this activity, so the bytes
 * are copied into our own cache here, before [finish], and the service is handed a plain path.
 * Passing the URI on instead would race the grant's revocation; passing the bytes in an Intent
 * extra would blow the ~1 MB Binder transaction limit on the first real photo. That copy runs on
 * a worker thread (a 50 MB video would ANR the main one) and the activity is deliberately kept
 * alive until it finishes — an invisible window costs nothing, and the grant dies with it.
 */
abstract class ShareActivity : Activity() {

  /** [FileFrame.DISP_CLIP] or [FileFrame.DISP_SAVE] — what the Mac should do with it. */
  protected abstract val disposition: String

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (!handle()) finish() // staging path finishes itself once the copy is done
  }

  /** Returns true when a worker thread took over and owns the [finish] call. */
  private fun handle(): Boolean {
    val intent = intent ?: return false
    val uri = streamExtra(intent)

    // A shared link or text block has no stream — send it as a clip, which is what the user
    // means by "share this to my Mac" for text, and costs nothing to support here.
    if (uri == null) {
      val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
      if (text.isNullOrBlank()) {
        toast(NOTHING_TO_SEND)
        return false
      }
      ClipForegroundService.submitClip(this, text)
      toast(if (ClipBus.peerOnline()) SENT else NOT_CONNECTED)
      return false
    }

    // Bail before copying anything when there is nowhere to send it. The outbound queue
    // (ConnectionManager.PENDING_MAX = 8 frames, 30 s TTL) can't hold a chunked file, and
    // silently dropping a photo the user explicitly shared is worse than saying so.
    if (!ClipBus.peerOnline()) {
      toast(NOT_CONNECTED)
      return false
    }

    val meta = queryMeta(uri)
    val mime = contentResolver.getType(uri) ?: intent.type ?: "application/octet-stream"
    if (meta.size > FileFrame.MAX_TRANSFER_BYTES) {
      toast("${meta.name} is too large (max ${FileFrame.MAX_TRANSFER_BYTES / (1024 * 1024)} MB)")
      return false
    }

    // Anything past a single chunk takes long enough that silence reads as a dead button, so
    // acknowledge the start here; ClipForegroundService toasts the outcome either way.
    if (meta.size > FileFrame.CHUNK_RAW_BYTES) toast("Sending ${meta.name}…")

    Thread {
      var staged: File? = null
      try {
        staged = stage(uri)
        // Can be refused with ForegroundServiceStartNotAllowedException if this activity died
        // while we were copying — Android 12+ only permits a foreground start. Inside the try so
        // that lands as a toast rather than an uncaught exception on this thread.
        ClipForegroundService.submitShare(this, staged.absolutePath, meta.name, mime, disposition)
      } catch (e: Exception) {
        ClipBus.log("share: send not started: ${e.message}")
        staged?.delete() // nothing will pick it up now; don't leave a copy of the file behind
        runOnUiThread { toast(COULD_NOT_SEND) }
      }
      runOnUiThread { finish() }
    }.start()
    return true
  }

  /** Copy the shared stream into our own cache, so the read happens while this activity (and
   *  therefore its URI grant) is still alive. Returns the staged file; the service deletes it. */
  private fun stage(uri: Uri): File {
    val dir = File(cacheDir, OUTBOX).apply { mkdirs() }
    // Reap anything a previous send left behind (a process death between staging and sending).
    val cutoff = System.currentTimeMillis() - STAGE_REAP_MS
    dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }

    val out = File(dir, UUID.randomUUID().toString())
    contentResolver.openInputStream(uri).use { input ->
      requireNotNull(input) { "no stream for $uri" }
      out.outputStream().use { input.copyTo(it) }
    }
    return out
  }

  /** Display name + byte size from the content provider, with sane fallbacks — a provider is
   *  allowed to answer neither. */
  private fun queryMeta(uri: Uri): Meta {
    var name: String? = null
    var size = -1L
    try {
      contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
        ?.use { c ->
          if (c.moveToFirst()) {
            val nameCol = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeCol = c.getColumnIndex(OpenableColumns.SIZE)
            if (nameCol >= 0 && !c.isNull(nameCol)) name = c.getString(nameCol)
            if (sizeCol >= 0 && !c.isNull(sizeCol)) size = c.getLong(sizeCol)
          }
        }
    } catch (e: Exception) {
      ClipBus.log("share: metadata query failed: ${e.message}")
    }
    return Meta(name ?: uri.lastPathSegment ?: "shared", size)
  }

  private class Meta(val name: String, val size: Long)

  @Suppress("DEPRECATION") // the typed overload is API 33+; this module ships to API 30.
  private fun streamExtra(intent: Intent): Uri? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
      intent.getParcelableExtra(Intent.EXTRA_STREAM)
    }

  private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

  private companion object {
    const val OUTBOX = "outbox"
    const val STAGE_REAP_MS = 5 * 60 * 1000L
    const val SENT = "Sent to your Mac"
    const val NOT_CONNECTED = "Your Mac isn't connected"
    const val NOTHING_TO_SEND = "Nothing to send"
    const val COULD_NOT_SEND = "Couldn't send that file"
  }
}

/**
 * Share-sheet entry that puts the shared image on the Mac's clipboard, ready to paste.
 * Filtered to images in the manifest: nothing else is pasteable on the other end.
 */
class ShareToClipboardActivity : ShareActivity() {
  override val disposition: String get() = FileFrame.DISP_CLIP
}

/**
 * Share-sheet entry that saves the shared file, at original quality, into the folder configured
 * on the Mac. Accepts every mime type — this is the entry that takes anything.
 */
class ShareAsFileActivity : ShareActivity() {
  override val disposition: String get() = FileFrame.DISP_SAVE
}
