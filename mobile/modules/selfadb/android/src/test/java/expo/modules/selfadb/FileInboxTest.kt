package expo.modules.selfadb

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Mirrors the Mac's `FileInboxTests`: the two reassemblers are hand-mirrored and must agree. */
class FileInboxTest {
  @get:Rule val tmp = TemporaryFolder()

  private fun inbox(ttlMs: Long = 120_000L) = FileInbox(tmp.newFolder(), ttlMs) { }

  /** Built directly (not via encode/parse) so a 64 MB case doesn't copy the payload twice. */
  private fun frame(id: String, seq: Int, count: Int, bytes: ByteArray, name: String? = "f.bin") = FileFrame(
    op = FileFrame.OP_DATA, mime = "x/y", name = name, dir = null, disp = FileFrame.DISP_SAVE,
    id = id, seq = seq, count = count, bytes = bytes, reason = null,
  )

  /** The inbox writes chunk N at `N * CHUNK_RAW_BYTES`, so real chunks are exactly that size. */
  private fun chunk(seq: Int, size: Int = FileFrame.CHUNK_RAW_BYTES) = ByteArray(size) { (seq * 31 + it).toByte() }

  @Test fun outOfOrderChunksReassembleByPosition() {
    val inbox = inbox()
    val c0 = chunk(0); val c1 = chunk(1); val c2 = chunk(2, size = 100)
    assertTrue(inbox.accept(frame("a", 2, 3, c2)) is FileInbox.Result.Buffered)
    assertTrue(inbox.accept(frame("a", 0, 3, c0)) is FileInbox.Result.Buffered)
    val done = inbox.accept(frame("a", 1, 3, c1)) as FileInbox.Result.Done
    assertArrayEquals(c0 + c1 + c2, done.completed.file.readBytes())
    assertEquals(FileFrame.DISP_SAVE, done.completed.disp)
  }

  @Test fun bufferedReportsProgress() {
    val r = inbox().accept(frame("p", 0, 4, chunk(0))) as FileInbox.Result.Buffered
    assertEquals(1, r.received)
    assertEquals(4, r.total)
  }

  @Test fun aDuplicateChunkDoesNotDoubleCount() {
    val inbox = inbox()
    inbox.accept(frame("d", 0, 2, chunk(0)))
    val again = inbox.accept(frame("d", 0, 2, chunk(0))) as FileInbox.Result.Buffered
    assertEquals(1, again.received) // still one distinct chunk
    val done = inbox.accept(frame("d", 1, 2, chunk(1, size = 10))) as FileInbox.Result.Done
    assertEquals((FileFrame.CHUNK_RAW_BYTES + 10).toLong(), done.completed.file.length())
  }

  @Test fun aThirdConcurrentTransferIsRejected() {
    val inbox = inbox()
    inbox.accept(frame("1", 0, 2, chunk(0)))
    inbox.accept(frame("2", 0, 2, chunk(0)))
    assertTrue(inbox.accept(frame("3", 0, 2, chunk(0))) is FileInbox.Result.Rejected)
  }

  @Test fun oversizeTransferIsRejectedAndItsTempFileRemoved() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir, maxBytes = 100) { }
    val r = inbox.accept(frame("big", 0, 2, ByteArray(101)))
    assertTrue(r is FileInbox.Result.Rejected)
    assertFalse(java.io.File(dir, "in-big").exists())
  }

  @Test fun outOfRangeChunksAreRejected() {
    val inbox = inbox()
    assertTrue(inbox.accept(frame("r", 5, 3, chunk(0))) is FileInbox.Result.Rejected)
    assertTrue(inbox.accept(frame("r", -1, 3, chunk(0))) is FileInbox.Result.Rejected)
    assertTrue(inbox.accept(frame("r", 0, 0, chunk(0))) is FileInbox.Result.Rejected)
  }

  @Test fun aChangedChunkCountMidTransferDropsIt() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir) { }
    inbox.accept(frame("c", 0, 3, chunk(0)))
    assertTrue(inbox.accept(frame("c", 1, 4, chunk(1))) is FileInbox.Result.Rejected)
    assertFalse(java.io.File(dir, "in-c").exists())
  }

  @Test fun anIdlessFrameIsRejected() {
    val f = FileFrame(FileFrame.OP_DATA, "x/y", "f", null, FileFrame.DISP_SAVE, null, 0, 1, ByteArray(1), null)
    assertTrue(inbox().accept(f) is FileInbox.Result.Rejected)
  }

  @Test fun anAbandonedTransferIsSweptAndItsTempFileDeleted() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir, ttlMs = 50) { }
    inbox.accept(frame("old", 0, 2, chunk(0)))
    assertTrue(java.io.File(dir, "in-old").exists())
    Thread.sleep(150)
    inbox.accept(frame("new", 0, 2, chunk(0))) // sweep runs at the start of every accept
    assertFalse(java.io.File(dir, "in-old").exists())
    assertTrue(java.io.File(dir, "in-new").exists())
  }

  @Test fun haveReportsTheContiguousPrefix() {
    val inbox = inbox()
    fun have(seq: Int) = (inbox.accept(frame("h", seq, 6, chunk(seq))) as FileInbox.Result.Buffered).have
    assertEquals(1, have(0))
    assertEquals(2, have(1))
    assertEquals(2, have(3)) // a gap at 2
    assertEquals(4, have(2)) // filling it jumps over 3
    assertEquals(4, have(2)) // a duplicate changes nothing
  }

  @Test fun aStalePartialIsEvictedToMakeRoom() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir, staleMs = 50) { }
    inbox.accept(frame("1", 0, 2, chunk(0)))
    inbox.accept(frame("2", 0, 2, chunk(0)))
    Thread.sleep(150)
    assertTrue(inbox.accept(frame("3", 0, 2, chunk(0))) is FileInbox.Result.Buffered)
    assertFalse(java.io.File(dir, "in-1").exists()) // the oldest idle one was dropped
    assertTrue(java.io.File(dir, "in-3").exists())
  }

  @Test fun aLiveTransferIsNeverEvicted() {
    val inbox = FileInbox(tmp.newFolder(), staleMs = 60_000) { }
    inbox.accept(frame("1", 0, 2, chunk(0)))
    inbox.accept(frame("2", 0, 2, chunk(0)))
    assertTrue(inbox.accept(frame("3", 0, 2, chunk(0))) is FileInbox.Result.Rejected)
  }

  @Test fun aQuietPartialIsKeptSoARetryResumes() {
    val inbox = FileInbox(tmp.newFolder(), ttlMs = 60_000, staleMs = 50) { }
    inbox.accept(frame("r", 0, 3, chunk(0)))
    inbox.accept(frame("r", 1, 3, chunk(1)))
    Thread.sleep(150) // quiet longer than staleMs, far less than the TTL
    val again = inbox.accept(frame("r", 0, 3, chunk(0))) as FileInbox.Result.Buffered
    assertEquals(2, again.have)
  }

  @Test fun aChunkLargerThanTheChunkSizeIsRejected() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir) { }
    // Written at seq * CHUNK_RAW_BYTES, it would overwrite the next chunk.
    assertTrue(inbox.accept(frame("big", 0, 2, chunk(0, size = FileFrame.CHUNK_RAW_BYTES + 1))) is FileInbox.Result.Rejected)
    assertFalse(java.io.File(dir, "in-big").exists())
  }

  @Test fun aHostileIdCannotTraverseOutOfTheInboxDirectory() {
    val dir = tmp.newFolder()
    val inbox = FileInbox(dir) { }
    inbox.accept(frame("../../evil", 0, 2, chunk(0)))
    assertTrue(dir.listFiles()!!.all { it.parentFile == dir })
    assertFalse(java.io.File(dir.parentFile, "evil").exists())
  }

  @Test fun oldLeftoversArePurgedWhenTheInboxIsCreated() {
    val dir = tmp.newFolder()
    val old = java.io.File(dir, "in-old").apply { writeText("x"); setLastModified(System.currentTimeMillis() - 2 * 60 * 60 * 1000L) }
    val fresh = java.io.File(dir, "in-fresh").apply { writeText("x") }
    FileInbox(dir) { }
    assertFalse(old.exists())
    assertTrue(fresh.exists())
  }
}
