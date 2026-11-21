package expo.modules.selfadb

/**
 * Which Mac address the phone should try on the LAN, in what order. mDNS used to be the only way to find the Mac, and an address was never
 * remembered, so a network that drops multicast meant no LAN at all. Now several sources feed one small book:
 *
 *   DISCOVERED (mDNS just found it) > HINT (the Mac told us over any link, `stat.lan`) > SEED (typed in by hand) > REMEMBERED (the last one that worked)
 *
 * and an address that actually joined ("joined") outranks all of them. An address that failed twice is skipped until [resetFailures] (a new
 * network). At most [maxEntries] are kept. Plain Kotlin, no clock, no Android types. **It never prints an address** (the privacy lint forbids
 * logging one, and an accidental `toString` would be the same leak).
 */
class LanHostBook(private val maxEntries: Int = 4, private val maxFailures: Int = 2) {
  enum class Source(val priority: Int) { REMEMBERED(1), SEED(2), HINT(3), DISCOVERED(4) }

  /** One address to try. [source] is the best source it currently has. */
  data class Entry(val host: String, val port: Int, val source: Source, val joined: Boolean) {
    override fun toString() = "Entry(source=$source, joined=$joined, port=$port)"
  }

  private class Slot(val host: String, val port: Int, val seq: Int) {
    val sources = HashSet<Source>()
    var failures = 0
    var joined = false
    val top: Source get() = sources.maxByOrNull { it.priority }!!
    fun entry() = Entry(host, port, top, joined)
  }

  private val slots = ArrayList<Slot>()
  private var seq = 0

  /** Most preferred first: the joined one, then by source priority, then by when it was first added. */
  private val order = compareByDescending<Slot> { it.joined }.thenByDescending { it.top.priority }.thenBy { it.seq }

  /** Adds (or refreshes) an address under [source]. False when the address is not usable. */
  fun add(host: String, port: Int, source: Source): Boolean {
    if (host.isBlank() || port !in 1..65535) return false
    slotFor(host, port).sources += source
    trim()
    return true
  }

  /** The Mac's latest hints replace the previous hints (a changed network must not leave stale ones); other sources are untouched. */
  fun offerHints(hints: List<StatLan.Hint>) {
    slots.forEach { it.sources -= Source.HINT }
    slots.removeAll { it.sources.isEmpty() && !it.joined }
    for (h in hints) if (h.host.isNotBlank() && h.port in 1..65535) slotFor(h.host, h.port).sources += Source.HINT
    trim()
  }

  /** The address to try now, or null when there is none left that has not failed. */
  fun best(): Entry? = slots.filter { it.failures < maxFailures }.minWithOrNull(order)?.entry()

  /** Every address, most preferred first (failed ones included). */
  fun entries(): List<Entry> = slots.sortedWith(order).map { it.entry() }

  fun markFailed(host: String, port: Int) {
    slots.firstOrNull { it.host == host && it.port == port }?.let { it.failures++ }
  }

  /** The LAN link to this address authenticated: forgive it, prefer it from now on, and remember it. */
  fun markJoined(host: String, port: Int) {
    if (host.isBlank() || port !in 1..65535) return
    slots.forEach { it.joined = false }
    val s = slotFor(host, port)
    s.sources += Source.REMEMBERED
    s.failures = 0
    s.joined = true
    trim()
  }

  fun resetFailures() = slots.forEach { it.failures = 0 }

  override fun toString() = "LanHostBook(${slots.size} entries)"

  private fun slotFor(host: String, port: Int): Slot =
    slots.firstOrNull { it.host == host && it.port == port } ?: Slot(host, port, seq++).also { slots += it }

  private fun trim() {
    while (slots.size > maxEntries) slots.remove(slots.sortedWith(order).last())
  }
}
