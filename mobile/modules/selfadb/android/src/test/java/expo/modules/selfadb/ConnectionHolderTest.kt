package expo.modules.selfadb

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The service must never hold two live ConnectionManagers: both would join the Mac's single-peer LAN server and evict each other (measured on
 * a phone: nine "lan authenticated" in ten seconds, plus a repeating SMS backfill). The old code checked `conn != null` and assigned `conn`
 * from two threads (the service's start and the JS `setRelay`) with no lock.
 */
class ConnectionHolderTest {
  /** A stand-in connection that counts how many are alive. */
  private class Fake(val id: Int, val alive: AtomicInteger) {
    init { alive.incrementAndGet() }
    var closed = 0
    fun close() { closed++; alive.decrementAndGet() }
  }

  private val alive = AtomicInteger(0)
  private val made = AtomicInteger(0)
  private val holder = ConnectionHolder<Fake> { it.close() }
  private fun make() = Fake(made.incrementAndGet(), alive)

  @Test fun ensureCreatesOnceAndReturnsTheSameOne() {
    val a = holder.ensure { make() }
    val b = holder.ensure { make() }
    assertSame(a, b)
    assertEquals(1, made.get())
    assertSame(a, holder.get())
  }

  @Test fun aFactoryThatReturnsNullLeavesTheHolderEmpty() {
    assertNull(holder.ensure { null })
    assertNull(holder.get())
    assertEquals(0, alive.get())
    // and a later ensure still works
    assertTrue(holder.ensure { make() } != null)
  }

  @Test fun aFactoryThatThrowsLeavesTheHolderUsable() {
    try { holder.ensure { error("boom") } } catch (_: IllegalStateException) {}
    assertNull(holder.get())
    assertTrue("the lock must be released", holder.ensure { make() } != null)
    assertEquals(1, alive.get())
  }

  @Test fun replaceShutsTheOldOneDownExactlyOnceThenCreatesTheNew() {
    val old = holder.ensure { make() }!!
    val fresh = holder.replace { make() }!!
    assertNotSame(old, fresh)
    assertEquals(1, old.closed)
    assertEquals(0, fresh.closed)
    assertEquals(1, alive.get())
    assertSame(fresh, holder.get())
  }

  @Test fun replaceOnAnEmptyHolderJustCreates() {
    val fresh = holder.replace { make() }!!
    assertSame(fresh, holder.get())
    assertEquals(1, alive.get())
  }

  @Test fun clearShutsDownOnceAndIsIdempotent() {
    val c = holder.ensure { make() }!!
    holder.clear()
    holder.clear()
    assertEquals(1, c.closed)
    assertNull(holder.get())
    assertEquals(0, alive.get())
  }

  @Test fun aShutdownThatThrowsStillLeavesTheOldOneForgotten() {
    val h = ConnectionHolder<Fake> { it.close(); error("close failed") }
    val old = h.ensure { make() }!!
    try { h.replace { make() } } catch (_: IllegalStateException) {}
    // the old one is not kept as current, whatever happened to the new one
    assertTrue(h.get() !== old)
    assertEquals(1, old.closed)
  }

  /** THE regression: many threads ask for a connection at once while creating one is slow. Exactly one must be made. */
  @Test fun concurrentEnsureMakesExactlyOne() {
    val n = 32
    val pool = Executors.newFixedThreadPool(n)
    val barrier = CyclicBarrier(n)
    val results = CopyOnWriteArrayList<Fake?>()
    val done = CountDownLatch(n)
    repeat(n) {
      pool.execute {
        barrier.await()
        results += holder.ensure { Thread.sleep(25); make() }
        done.countDown()
      }
    }
    assertTrue(done.await(20, TimeUnit.SECONDS))
    pool.shutdownNow()
    assertEquals("one connection created, not $made", 1, made.get())
    assertEquals(1, results.map { it!!.id }.toSet().size)
    assertEquals(1, alive.get())
  }

  /** The service's two entry points interleave: `onStartCommand` (ensure) and JS `setRelay` (replace). Never two alive at once. */
  @Test fun ensureAndReplaceInterleavingNeverLeavesTwoAlive() {
    val peak = AtomicInteger(0)
    val h = ConnectionHolder<Fake> { it.close() }
    val pool = Executors.newFixedThreadPool(8)
    val barrier = CyclicBarrier(8)
    val done = CountDownLatch(8)
    repeat(8) { i ->
      pool.execute {
        barrier.await()
        repeat(40) {
          val make = { Thread.sleep(1); make().also { peak.accumulateAndGet(alive.get()) { a, b -> maxOf(a, b) } } }
          if (i % 2 == 0) h.ensure(make) else h.replace(make)
        }
        done.countDown()
      }
    }
    assertTrue(done.await(60, TimeUnit.SECONDS))
    pool.shutdownNow()
    assertEquals("never more than one alive", 1, peak.get())
    assertEquals(1, alive.get())
  }
}
