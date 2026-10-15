package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class FileHistoryTest {
  @get:Rule val tmp = TemporaryFolder()

  private fun file() = File(tmp.root, "history.json")

  private fun entry(id: String, status: String = "done", direction: String = "in", source: String? = null) = HistoryEntry(
    id = id, direction = direction, name = "$id.bin", size = 10, ts = 1_000, status = status, source = source,
  )

  @Test fun newestFirstAndReplacedById() {
    val store = FileHistoryStore(file())
    store.upsert(entry("a"))
    store.upsert(entry("b"))
    assertEquals(listOf("b", "a"), store.list().map { it.id })
    store.upsert(entry("a", status = "failed"))
    assertEquals(listOf("b", "a"), store.list().map { it.id }) // replaced in place, not duplicated
    assertEquals("failed", store.find("a")?.status)
  }

  @Test fun isBounded() {
    val store = FileHistoryStore(file(), max = 3)
    (1..5).forEach { store.upsert(entry("e$it")) }
    assertEquals(listOf("e5", "e4", "e3"), store.list().map { it.id })
  }

  @Test fun survivesARestart() {
    FileHistoryStore(file()).apply {
      upsert(entry("kept", direction = "out", status = "failed", source = "content://x/1"))
    }
    val again = FileHistoryStore(file())
    val e = again.find("kept")!!
    assertEquals("out", e.direction)
    assertEquals("content://x/1", e.source)
    assertEquals("kept.bin", e.name)
  }

  @Test fun nullableFieldsRoundTripAsNull() {
    FileHistoryStore(file()).upsert(entry("n"))
    val e = FileHistoryStore(file()).find("n")!!
    assertNull(e.dir)
    assertNull(e.error)
    assertNull(e.uri)
    assertNull(e.source)
  }

  @Test fun anInterruptedTransferIsMarkedFailedOnLoad() {
    FileHistoryStore(file()).apply {
      upsert(entry("q", status = "queued", direction = "out"))
      upsert(entry("p", status = "active", direction = "out"))
      upsert(entry("d", status = "done"))
    }
    val again = FileHistoryStore(file())
    assertEquals("failed", again.find("q")?.status)
    assertEquals("Interrupted", again.find("p")?.error)
    assertEquals("done", again.find("d")?.status) // a finished one is untouched
  }

  @Test fun aProgressTickIsNotPersisted() {
    val store = FileHistoryStore(file())
    store.upsert(entry("a", status = "active", direction = "out"), persist = false)
    assertFalse(file().exists()) // nothing written for a tick…
    assertEquals("active", store.find("a")?.status) // …but it is visible in memory
  }

  @Test fun clearEmptiesTheFileToo() {
    val store = FileHistoryStore(file())
    store.upsert(entry("a"))
    store.clear()
    assertTrue(FileHistoryStore(file()).list().isEmpty())
  }

  @Test fun aCorruptFileStartsOverInsteadOfThrowing() {
    file().writeText("{not json")
    val store = FileHistoryStore(file())
    assertTrue(store.list().isEmpty())
    store.upsert(entry("fresh"))
    assertEquals(1, FileHistoryStore(file()).list().size)
  }

  @Test fun onlyAnUnfinishedSendWithASourceIsRetryable() {
    assertTrue(entry("a", status = "failed", direction = "out", source = "content://x").retryable)
    assertTrue(entry("a", status = "cancelled", direction = "out", source = "content://x").retryable)
    assertFalse(entry("a", status = "failed", direction = "out", source = null).retryable) // share-sheet: no grant
    assertFalse(entry("a", status = "done", direction = "out", source = "content://x").retryable)
    assertFalse(entry("a", status = "failed", direction = "in", source = "content://x").retryable)
  }
}
