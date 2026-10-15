package expo.modules.selfadb

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract

/** One entry of a document tree (a folder or a file), as a provider reports it. */
data class Doc(
  val id: String,
  val name: String,
  val isDir: Boolean,
  val size: Long,
  val mime: String,
  /** Last-modified in seconds, 0 when unknown. */
  val modified: Long,
)

/** The only thing [FolderWalker] needs from a provider — so a fake can stand in for it in tests. */
interface DocTree {
  fun children(parentId: String): List<Doc>
}

/** A file found by [FolderWalker], with its folder path relative to (and including) the picked root. */
class WalkedFile(val doc: Doc, val dir: String)

class Walk(val files: List<WalkedFile>, val problems: List<String>)

/**
 * Flattens a folder the user picked into the files to send, keeping each one's folder path so the
 * Mac can recreate the tree. Hidden entries (a leading `.`) are skipped; empty and oversized files,
 * a folder with nothing in it, and anything past [MAX_FILES] become `problems` for the closing
 * toast instead of silently vanishing. The walk is bounded in depth as well, so a pathological or
 * cyclic provider can't spin it.
 */
object FolderWalker {
  const val MAX_FILES = 1000
  const val MAX_DEPTH = 16

  fun walk(
    tree: DocTree,
    rootId: String,
    rootName: String,
    maxFiles: Int = MAX_FILES,
    maxBytes: Long = FileFrame.MAX_TRANSFER_BYTES.toLong(),
  ): Walk {
    val files = ArrayList<WalkedFile>()
    val problems = ArrayList<String>()
    var truncated = false

    fun visit(id: String, path: String, depth: Int) {
      if (truncated) return
      if (depth > MAX_DEPTH) {
        problems += "$path is nested too deep"
        return
      }
      // A stable order (files and folders by name) makes a repeat send identical to the first.
      for (d in tree.children(id).sortedBy { it.name.lowercase() }) {
        if (truncated) return
        if (d.name.startsWith(".")) continue
        if (d.isDir) {
          visit(d.id, "$path/${d.name}", depth + 1)
          continue
        }
        when {
          d.size <= 0L -> problems += "${d.name} is empty"
          d.size > maxBytes -> problems += "${d.name} is larger than the ${limitLabel(maxBytes)} limit"
          files.size >= maxFiles -> {
            problems += "$rootName: only the first $maxFiles files were queued"
            truncated = true
          }
          else -> files += WalkedFile(d, path)
        }
      }
    }

    visit(rootId, rootName, 0)
    if (files.isEmpty() && problems.isEmpty()) problems += "$rootName has no files to send"
    return Walk(files, problems)
  }

  private fun limitLabel(bytes: Long): String =
    if (bytes >= 1L shl 30) "${bytes shr 30} GB" else "${bytes shr 20} MB"
}

/** [DocTree] over a Storage Access Framework tree URI (`ACTION_OPEN_DOCUMENT_TREE`). */
class ContentResolverTree(private val resolver: ContentResolver, private val treeUri: Uri) : DocTree {
  override fun children(parentId: String): List<Doc> {
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
    val out = ArrayList<Doc>()
    resolver.query(childrenUri, PROJECTION, null, null, null)?.use { c ->
      while (c.moveToNext()) {
        val mime = c.getString(2) ?: ""
        out += Doc(
          id = c.getString(0),
          name = c.getString(1) ?: continue,
          isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR,
          size = if (c.isNull(3)) -1L else c.getLong(3),
          mime = mime,
          modified = if (c.isNull(4)) 0L else c.getLong(4) / 1000,
        )
      }
    }
    return out
  }

  /** The picked folder's own name (what becomes the top of every file's `dir`). */
  fun rootName(): String {
    val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
    resolver.query(rootUri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
      if (c.moveToFirst()) c.getString(0)?.let { return it }
    }
    return "Folder"
  }

  fun rootId(): String = DocumentsContract.getTreeDocumentId(treeUri)

  fun documentUri(docId: String): Uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)

  private companion object {
    val PROJECTION = arrayOf(
      DocumentsContract.Document.COLUMN_DOCUMENT_ID,
      DocumentsContract.Document.COLUMN_DISPLAY_NAME,
      DocumentsContract.Document.COLUMN_MIME_TYPE,
      DocumentsContract.Document.COLUMN_SIZE,
      DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )
  }
}
