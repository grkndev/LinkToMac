package expo.modules.selfadb

import org.json.JSONArray
import org.json.JSONObject

/**
 * `stat.lan`: the Mac's LAN address hint. The Mac writes the private IPv4 addresses of its Ethernet/Wi-Fi interfaces into its own `stat`
 * (`"lan":["192.168.1.10:53124", …]`, end-to-end encrypted like every `stat`). The phone uses them to reach the Mac's LAN-direct server when
 * mDNS multicast does not get through — measured on a campus Wi-Fi: the phone's NSD sent six queries and found nothing while the Mac
 * advertised normally.
 *
 * The hint is **untrusted input** (the LAN handshake still authenticates whoever answers), so parsing is strict and never fatal: a malformed item
 * is skipped, a malformed field is "no information". Swift twin: `StatLan` in `LanAddressHint.swift`; both run
 * `protocol-vectors/stat-lan.json` (`parse`). Plain Kotlin + org.json so a JVM test runs it.
 */
object StatLan {
  const val MAX_HINTS = 3
  private const val MAX_ITEM_CHARS = 21 // "255.255.255.255:65535"
  private const val MIN_PORT = 1024
  private const val MAX_PORT = 65535

  data class Hint(val host: String, val port: Int) {
    /** Never prints the address: this object can end up in a log line by accident. */
    override fun toString() = "Hint(port=$port)"
  }

  sealed class Update {
    /** No usable `lan` (missing, or not an array): the receiver keeps what it has. */
    object Absent : Update() {
      override fun toString() = "Absent"
    }

    /** The accepted hints in order, possibly none. */
    data class Hints(val hints: List<Hint>) : Update()
  }

  private val OCTET = Regex("^(0|[1-9][0-9]{0,2})$")
  private val PORT = Regex("^[1-9][0-9]{0,4}$")

  fun parse(stat: JSONObject): Update {
    val raw = stat.opt("lan") as? JSONArray ?: return Update.Absent
    val out = LinkedHashSet<Hint>()
    for (i in 0 until raw.length()) {
      if (out.size >= MAX_HINTS) break
      val item = raw.opt(i) as? String ?: continue
      parseItem(item)?.let { out += it }
    }
    return Update.Hints(out.toList())
  }

  /** One `"a.b.c.d:port"`, or null. */
  fun parseItem(item: String): Hint? {
    if (item.length > MAX_ITEM_CHARS) return null
    val halves = item.split(':')
    if (halves.size != 2) return null
    val (ip, portText) = halves
    if (!isPrivateIpv4(ip)) return null
    if (!PORT.matches(portText)) return null
    val port = portText.toInt()
    if (port !in MIN_PORT..MAX_PORT) return null
    return Hint(ip, port)
  }

  /** A canonical dotted IPv4 inside 10/8, 172.16/12 or 192.168/16. */
  fun isPrivateIpv4(ip: String): Boolean {
    val parts = ip.split('.')
    if (parts.size != 4 || parts.any { !OCTET.matches(it) }) return false
    val o = parts.map { it.toInt() }
    if (o.any { it > 255 }) return false
    return o[0] == 10 || (o[0] == 172 && o[1] in 16..31) || (o[0] == 192 && o[1] == 168)
  }
}
