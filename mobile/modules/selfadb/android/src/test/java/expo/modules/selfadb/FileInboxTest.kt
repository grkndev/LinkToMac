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
    val inbox = FileInbox(dir) { }
    val r = inbox.accept(frame("big", 0, 2, ByteArray(FileFrame.MAX_TRANSFER_BYTES + 1)))
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
}
