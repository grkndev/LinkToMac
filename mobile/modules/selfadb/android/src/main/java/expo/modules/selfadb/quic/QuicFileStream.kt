package expo.modules.selfadb.quic

import org.json.JSONObject
import org.json.JSONTokener

/**
 * The bytes of one QUIC file stream (stage 2.2 of `docs/plans/2026-11-14-quic-data-plane.md`, Faz 2): one bidirectional stream per file.
 *
 *     sender   ->  0x01 (the file channel varint)  ‖  header message
 *     receiver ->  {"have":N}  or  {"err":"…","ok":false}          (N = bytes it already holds, 0 <= N <= size)
 *     sender   ->  exactly size - have raw bytes, then it closes its side
 *     receiver ->  {"ok":true}  (only after the file is in its final place)  or  {"err":"…","ok":false}
 *
 * Every message is `u16 BE length ‖ JSON`. Pure (plain Kotlin + org.json, no Android types), so a JVM test runs it. The Swift twin is
 * `QuicFileStream` in `Quic/QuicFileStream.swift` and the Rust one is `quic-core/src/file.rs`; all three run the `file_stream` section of
 * `protocol-vectors/quic-control.json`. Nothing here touches a socket or a file name: the receivers sanitise the name and directory
 * themselves (stages 2.3 / 2.4); this layer only checks the syntax and the limits.
 */
object QuicFileStream {
  const val HEADER_MAX_BYTES = 4096
  const val NAME_MAX_BYTES = 200
  const val MIME_MAX_BYTES = 255

  /** How long a receiver waits for the first byte of a bidirectional stream before it ignores the stream (Network.framework's reserved, byte-less stream). */
  const val FIRST_BYTE_TIMEOUT_MS = 2000

  /** 2^53 - 1: every JSON library reads it exactly. */
  const val SIZE_MAX = 9_007_199_254_740_991L

  data class Header(val dir: String?, val id: String, val mime: String, val mtime: Long, val name: String, val size: Long)

  /** The refusal codes on the wire. */
  enum class WireError(val wire: String) {
    SPACE("space"), BUSY("busy"), BAD_ID("bad-id"), WRITE("write"), TOO_MANY("too-many"), BAD_HEADER("bad-header"), SIZE("size"),
  }

  /** A refusal the peer sent: a code we know, or one a newer peer invented (or none at all). */
  sealed class Refusal {
    data class Known(val code: WireError) : Refusal()
    object Unknown : Refusal() {
      override fun toString() = "Unknown"
    }
  }

  enum class HeaderInvalid {
    /** The first varint names another channel: not ours, nothing is answered. */
    NOT_FILE,

    /** Anything wrong with the structure or the limits. */
    BAD_HEADER,

    /** The structure is fine but `id` is not 8 lower-case hex (checked last). */
    BAD_ID,
  }

  sealed class HeaderResult {
    object NeedMore : HeaderResult() {
      override fun toString() = "NeedMore"
    }

    /** The header, and how many bytes it used; later bytes belong to the body. */
    data class Parsed(val header: Header, val consumed: Int) : HeaderResult()

    data class Invalid(val why: HeaderInvalid) : HeaderResult()
  }

  /** Feeds the bytes the way a stream delivers them. The answer for the bytes so far; an invalid is final, NeedMore is not. */
  class HeaderDecoder {
    private var buffer = ByteArray(0)
    fun feed(bytes: ByteArray): HeaderResult {
      buffer += bytes
      return decodeHeader(buffer)
    }
  }

  // ---- header -------------------------------------------------------------------------------

  /** What a sender writes first: the file channel varint and the header message (canonical JSON). The sender keeps the header within the limits. */
  fun encodeHeader(h: Header): ByteArray {
    val json = buildString {
      append('{')
      if (h.dir != null) append("\"dir\":").append(quoted(h.dir)).append(',')
      append("\"id\":").append(quoted(h.id)).append(",\"mime\":").append(quoted(h.mime))
      append(",\"mtime\":").append(h.mtime).append(",\"name\":").append(quoted(h.name)).append(",\"size\":").append(h.size).append('}')
    }
    return byteArrayOf(QuicChannel.FILE.typeId.toByte()) + message(json)
  }

  /** The answer for ALL the bytes received so far. */
  fun decodeHeader(bytes: ByteArray): HeaderResult {
    val channelLength = when (val p = QuicChannel.parse(bytes)) {
      is ChannelParse.NeedMoreBytes -> return HeaderResult.NeedMore
      is ChannelParse.Unknown -> return HeaderResult.Invalid(HeaderInvalid.NOT_FILE)
      is ChannelParse.Known -> if (p.channel == QuicChannel.FILE) p.consumed else return HeaderResult.Invalid(HeaderInvalid.NOT_FILE)
    }
    if (bytes.size < channelLength + 2) return HeaderResult.NeedMore
    val length = (bytes[channelLength].toInt() and 0xff shl 8) or (bytes[channelLength + 1].toInt() and 0xff)
    if (length == 0 || length > HEADER_MAX_BYTES) return HeaderResult.Invalid(HeaderInvalid.BAD_HEADER) // known as soon as the two length bytes are
    val end = channelLength + 2 + length
    if (bytes.size < end) return HeaderResult.NeedMore
    val header = parseHeaderBody(bytes.copyOfRange(channelLength + 2, end)) ?: return HeaderResult.Invalid(HeaderInvalid.BAD_HEADER)
    if (!isId(header.id)) return HeaderResult.Invalid(HeaderInvalid.BAD_ID)
    return HeaderResult.Parsed(header, end)
  }

  /** Structure and limits. The id's PATTERN is checked by the caller afterwards so that a structural fault wins over a bad id. */
  private fun parseHeaderBody(body: ByteArray): Header? {
    val o = jsonObject(body) ?: return null
    val name = o.opt("name") as? String ?: return null
    if (name.toByteArray(Charsets.UTF_8).size !in 1..NAME_MAX_BYTES) return null
    val mime = o.opt("mime") as? String ?: return null
    if (mime.toByteArray(Charsets.UTF_8).size !in 1..MIME_MAX_BYTES) return null
    val size = integer(o.opt("size")) ?: return null
    val mtime = integer(o.opt("mtime")) ?: return null
    val id = o.opt("id") as? String ?: return null
    var dir: String? = null
    if (o.has("dir")) dir = o.opt("dir") as? String ?: return null
    return Header(dir, id, mime, mtime, name, size)
  }

  private fun isId(s: String): Boolean = s.length == 8 && s.all { it in '0'..'9' || it in 'a'..'f' }

  // ---- answers ------------------------------------------------------------------------------

  fun encodeHave(have: Long): ByteArray = message("{\"have\":$have}")

  /** `{"ok":true}`, or a refusal with its code (`{"err":"space","ok":false}`). */
  fun encodeResult(ok: Boolean, err: WireError? = null): ByteArray = when {
    ok -> message("{\"ok\":true}")
    err != null -> message("{\"err\":\"${err.wire}\",\"ok\":false}")
    else -> message("{\"ok\":false}")
  }

  sealed class HaveResult {
    data class Have(val bytes: Long) : HaveResult()
    data class Refused(val why: Refusal) : HaveResult()
    object Invalid : HaveResult() {
      override fun toString() = "Invalid"
    }
  }

  /** The first answer, as ONE complete message; [size] is the file's size (a `have` beyond it is invalid). */
  fun parseHave(bytes: ByteArray, size: Long): HaveResult {
    val o = messageBody(bytes)?.let { jsonObject(it) } ?: return HaveResult.Invalid
    if (o.has("ok")) {
      val flag = o.opt("ok") as? Boolean ?: return HaveResult.Invalid
      if (flag) return HaveResult.Invalid // `ok:true` is not an answer to the header
      return HaveResult.Refused(refusal(o.opt("err")))
    }
    val have = integer(o.opt("have")) ?: return HaveResult.Invalid
    return if (have <= size) HaveResult.Have(have) else HaveResult.Invalid
  }

  sealed class FinalResult {
    object Ok : FinalResult() {
      override fun toString() = "Ok"
    }

    data class Refused(val why: Refusal) : FinalResult()
    object Invalid : FinalResult() {
      override fun toString() = "Invalid"
    }
  }

  /** The last answer, as ONE complete message. */
  fun parseResult(bytes: ByteArray): FinalResult {
    val o = messageBody(bytes)?.let { jsonObject(it) } ?: return FinalResult.Invalid
    val ok = o.opt("ok") as? Boolean ?: return FinalResult.Invalid
    return if (ok) FinalResult.Ok else FinalResult.Refused(refusal(o.opt("err")))
  }

  // ---- the body -----------------------------------------------------------------------------

  /** How many raw bytes follow the first answer, or null when [have] is outside 0..size. */
  fun bodyLength(size: Long, have: Long): Long? = if (size >= 0 && have >= 0 && have <= size) size - have else null

  enum class Verdict { OK, SIZE_MISMATCH }

  /** The sender closed its side after [received] bytes while [expected] were due. */
  fun finishVerdict(expected: Long, received: Long): Verdict = if (expected == received) Verdict.OK else Verdict.SIZE_MISMATCH

  // ---- framing and JSON ---------------------------------------------------------------------

  /** How long the whole message is, once its two length bytes are known (null before that). */
  fun messageLength(prefix: ByteArray): Int? =
    if (prefix.size >= 2) 2 + ((prefix[0].toInt() and 0xff shl 8) or (prefix[1].toInt() and 0xff)) else null

  private fun message(json: String): ByteArray {
    val body = json.toByteArray(Charsets.UTF_8)
    return byteArrayOf((body.size shr 8 and 0xff).toByte(), (body.size and 0xff).toByte()) + body
  }

  /** The JSON of ONE complete message (length prefix matching the bytes), or null. */
  private fun messageBody(bytes: ByteArray): ByteArray? {
    val total = messageLength(bytes) ?: return null
    if (total != bytes.size || total <= 2 || total - 2 > HEADER_MAX_BYTES) return null
    return bytes.copyOfRange(2, bytes.size)
  }

  /** A JSON object and nothing after it (org.json alone would let trailing text through). */
  private fun jsonObject(body: ByteArray): JSONObject? = try {
    val tokener = JSONTokener(String(body, Charsets.UTF_8))
    val value = tokener.nextValue()
    if (value is JSONObject && tokener.nextClean() == 0.toChar()) value else null
  } catch (_: Exception) {
    null
  }

  /** A JSON integer literal 0..SIZE_MAX: not a boolean, not a float (`5.0` and `1e3` are floats), not a string, not beyond 64 bits. */
  private fun integer(v: Any?): Long? {
    val n = when (v) {
      is Int -> v.toLong()
      is Long -> v
      else -> return null
    }
    return if (n in 0..SIZE_MAX) n else null
  }

  private fun refusal(v: Any?): Refusal = WireError.values().firstOrNull { it.wire == v }?.let { Refusal.Known(it) } ?: Refusal.Unknown

  /** Canonical JSON string: `"` `\` and control characters escaped (`\b \f \n \r \t` short, the rest `\u00xx` lower case), everything else raw. */
  private fun quoted(s: String): String = buildString {
    append('"')
    for (c in s) when {
      c == '"' -> append("\\\"")
      c == '\\' -> append("\\\\")
      c == '\b' -> append("\\b")
      c == '\u000c' -> append("\\f")
      c == '\n' -> append("\\n")
      c == '\r' -> append("\\r")
      c == '\t' -> append("\\t")
      c < ' ' -> append(String.format("\\u%04x", c.code))
      else -> append(c)
    }
    append('"')
  }
}
