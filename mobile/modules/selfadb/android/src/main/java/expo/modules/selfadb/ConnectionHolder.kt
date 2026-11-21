package expo.modules.selfadb

/**
 * Owns the service's ONE live connection and makes "at most one" a property of the type, not of call order.
 *
 * Why it exists: the service's own start (`onStartCommand`) and the JS `setRelay` call both ask for a connection, on different threads. The
 * old code did `if (conn != null) return; conn = ConnectionManager(...)` with no lock, so both could pass the check and each build a manager.
 * The loser was never shut down, and two managers both join the Mac's single-peer LAN server, which evicts the older one: they took turns
 * reconnecting about once a second (nine "lan authenticated" in ten seconds, a repeating SMS backfill, a busy radio).
 *
 * Plain Kotlin (no Android types) so a JVM test can hammer it from many threads. The factory runs while the lock is held, which is the point:
 * creating is the slow part and must not be raced. That is safe because [ConnectionManager.start] only posts to its own executor and returns,
 * so nothing here waits on another thread that could be waiting on this lock.
 */
class ConnectionHolder<T : Any>(private val shutdown: (T) -> Unit) {
  private val lock = Any()
  private var current: T? = null

  /** The live connection, or null. */
  fun get(): T? = synchronized(lock) { current }

  /** The live connection; if there is none, make one with [create] (which may return null: nothing to connect to). Never makes a second. */
  fun ensure(create: () -> T?): T? = synchronized(lock) {
    current ?: create()?.also { current = it }
  }

  /** Shut the live connection down (if any) and make a fresh one. The old one is forgotten even if shutting it down throws. */
  fun replace(create: () -> T?): T? = synchronized(lock) {
    dropLocked()
    create()?.also { current = it }
  }

  /** Shut the live connection down (if any) and leave the holder empty. */
  fun clear() = synchronized(lock) { dropLocked() }

  private fun dropLocked() {
    val old = current ?: return
    current = null // forgotten first: a throwing shutdown must not leave a half-dead connection as "current"
    shutdown(old)
  }
}
