package expo.modules.selfadb

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * The system file / folder picker for the Files screen's "Send files" and "Send folder", behind an
 * invisible activity — the same shape as [ShareActivity]: the screen asks for a pick, this shows
 * the system picker, and the result goes straight to [ClipForegroundService] (which outlives both
 * this activity and the JS runtime) rather than back through JS.
 *
 * It takes a **persistent** read grant on whatever was picked (`takePersistableUriPermission`).
 * That is what lets the service stream the file without copying it, and what makes a failed send
 * retryable later: a share-sheet URI's grant dies with its activity, a picked one does not.
 */
class PickActivity : Activity() {
  private val folder: Boolean get() = intent?.getStringExtra(EXTRA_MODE) == MODE_FOLDER

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (savedInstanceState != null) return // a recreated activity must not open a second picker
    val picker = if (folder) {
      Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
    } else {
      Intent(Intent.ACTION_OPEN_DOCUMENT)
        .addCategory(Intent.CATEGORY_OPENABLE)
        .setType("*/*")
        .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
    }
    picker.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    try {
      @Suppress("DEPRECATION") // the Activity Result API needs a ComponentActivity; this is a plain Activity
      startActivityForResult(picker, REQUEST_PICK)
    } catch (e: Exception) {
      ClipBus.log("pick: no picker available: ${e.message}")
      Toast.makeText(this, "No file picker found", Toast.LENGTH_SHORT).show()
      finish()
    }
  }

  @Deprecated("see startActivityForResult above")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    try {
      if (requestCode == REQUEST_PICK && resultCode == RESULT_OK && data != null) {
        val uris = ArrayList<Uri>()
        data.data?.let { uris += it }
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris += it } }
        for (uri in uris) {
          try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
          } catch (e: Exception) {
            // Some providers don't offer a persistable grant: the send still works now, it just
            // can't be retried after the process restarts.
            ClipBus.log("pick: no persistable grant for $uri: ${e.message}")
          }
        }
        if (uris.isNotEmpty()) {
          if (!ClipBus.peerOnline()) {
            Toast.makeText(this, "Your Mac isn't connected", Toast.LENGTH_SHORT).show()
          } else if (folder) {
            ClipForegroundService.submitPick(this, emptyList(), uris.first())
          } else {
            ClipForegroundService.submitPick(this, uris.distinct(), null)
          }
        }
      }
    } catch (e: Exception) {
      ClipBus.log("pick: not started: ${e.message}")
      Toast.makeText(this, "Couldn't send that", Toast.LENGTH_SHORT).show()
    }
    finish()
  }

  companion object {
    const val EXTRA_MODE = "mode"
    const val MODE_FILES = "files"
    const val MODE_FOLDER = "folder"
    private const val REQUEST_PICK = 4711
  }
}
