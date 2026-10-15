package expo.modules.selfadb

import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * The `file` frame plaintext — what goes inside the v2 envelope under AAD "file".
 *
 *     u16 BE header-len ‖ header JSON (utf8) ‖ raw bytes
 *
 * **Byte-exact contract with the Mac's `FileFrame.swift`.** The two are hand-mirrored, not
 * generated; change both together (see the root CLAUDE.md invariant on the wire protocol).
 *
 * Header fields, all optional but [MIME], and all additive to the original `{"mime":…}` shape so
 * an older peer that only reads `mime` still pastes an image correctly:
 *
 * | key    | meaning                                                        | absent means      |
 * |--------|----------------------------------------------------------------|-------------------|
 * | `op`   | [OP_DATA] (payload), [OP_ACK] (receiver stored a seq) or [OP_NACK] (it could not) | [OP_DATA] |
 * | `mime` | content type of the payload                                    | `image/png`       |
 * | `name` | original file name, for [DISP_SAVE]                            | receiver invents  |
 * | `dir`  | relative folder the file sits in (`Photos/2024`), for [DISP_SAVE] | the download folder |
 * | `disp` | [DISP_CLIP] (paste it) or [DISP_SAVE] (write it to disk)       | [DISP_CLIP]       |
 * | `id`   | transfer id shared by every chunk of one file                  | single-frame      |
 * | `seq`  | 0-based chunk index                                            | 0                 |
 * | `n`    | total chunk count                                              | 1                 |
 * | `err`  | why a [OP_NACK] was sent (free text)                           | no reason given   |
 *
 * The header repeats in full on every chunk (it costs ~100 bytes and makes each chunk
 * self-describing, so the receiver never depends on chunk 0 arriving first).
 *
 * **[OP_ACK] is flow control, not politeness.** The relay drops any peer whose send buffer passes
 * `maxPayloadBytes * 8` (8 MiB) as a slow consumer — so firing a 50 MB file's ~80 chunks back to
 * back would disconnect the *Mac* mid-transfer. The receiver therefore acks every chunk it stores
 * and the sender keeps only a small window in flight. This layers extra ops onto an existing frame
 * type rather than adding a new one, exactly as the `sms` reply path does.
 */
class FileFrame(
  /** [OP_DATA] or [OP_ACK]. */
  val op: String,
  val mime: String,
  val name: String?,
  /** Relative folder path for a dropped folder's files; null = the download folder itself. */
  val dir: String?,
  val disp: String,
  /** Transfer id shared by a chunked file's frames; null for a single-frame transfer. */
  val id: String?,
  val seq: Int,
  val count: Int,
  val bytes: ByteArray,
  /** Why a [OP_NACK] was sent, when the receiver said. */
  val reason: String?,
) {
  /** True when this frame is the whole file (the pre-chunking shape, and any file under one chunk). */
  val isSingle: Boolean get() = id == null || count <= 1

  companion object {
    /** A frame carrying payload bytes (the original, and still the default). */
    const val OP_DATA = "data"

    /** A zero-byte frame acknowledging that [id]/[seq] was stored, so the sender may advance
     *  its window. Travels back down the same `file` channel. */
    const val OP_ACK = "ack"

    /** A zero-byte frame saying [id]/[seq] could NOT be stored (disk full, write failed, over a
     *  limit), so the sender stops now instead of waiting out its ack timeout and then claiming a
     *  delivery that never happened. */
    const val OP_NACK = "nack"

    /** Land on the receiver's clipboard (the original, and still the default). */
    const val DISP_CLIP = "clip"

    /** Write to the receiver's configured download folder. */
    const val DISP_SAVE = "save"

    /**
     * Raw payload bytes per chunk. The relay caps a frame at 1 MiB (`MAX_PAYLOAD_BYTES`), and a
     * frame is `{"t":"file","nonce":…,"ct":base64(8-byte ts ‖ payload ‖ 16-byte tag)}` — so
     * 640 KiB raw becomes ~853 KB of base64 plus ~60 bytes of JSON, a comfortable margin under
     * the cap. Bump this only together with the relay's `MAX_PAYLOAD_BYTES` **and** both
     * WebSocket `maximumMessageSize` settings on the Mac.
     */
    const val CHUNK_RAW_BYTES = 640 * 1024

    /** Refuse to even start a transfer bigger than this. At [CHUNK_RAW_BYTES] that is ~103
     *  frames; the Mac's reassembly buffer enforces the same ceiling. */
    const val MAX_TRANSFER_BYTES = 64 * 1024 * 1024

    /** Build one frame's plaintext. [seq]/[count]/[id] are omitted from the header for a
     *  single-frame transfer, keeping the bytes identical to what pre-chunking builds sent. */
    fun encode(
      mime: String,
      bytes: ByteArray,
      offset: Int = 0,
      length: Int = bytes.size,
      name: String? = null,
      dir: String? = null,
      disp: String = DISP_CLIP,
      id: String? = null,
      seq: Int = 0,
      count: Int = 1,
    ): ByteArray {
      val header = JSONObject().put("mime", mime)
      if (name != null) header.put("name", name)
      if (!dir.isNullOrEmpty()) header.put("dir", dir)
      if (disp != DISP_CLIP) header.put("disp", disp)
      // Emitted whenever the sender assigned an id, even for a one-chunk file: `id` is what
      // makes the receiver ack, and a "Send as a File" transfer wants that receipt at any size.
      // A clipboard send passes no id, so its bytes stay exactly what pre-chunking builds sent.
      if (id != null) header.put("id", id).put("seq", seq).put("n", count)
      val headerBytes = fitted(header).toString().toByteArray(Charsets.UTF_8)
      val out = ByteArrayOutputStream(2 + headerBytes.size + length)
      out.write((headerBytes.size shr 8) and 0xFF)
      out.write(headerBytes.size and 0xFF)
      out.write(headerBytes)
      out.write(bytes, offset, length)
      return out.toByteArray()
    }

    /** The header length is a u16, so it can never exceed this. */
    private const val MAX_HEADER_BYTES = 0xFFFF

    /** Keep a header under the u16 limit — mirrors the Mac's `FileFrame.fitted` (a shared vector
     *  pins both). A file name and folder path are user data of unbounded length, and a longer
     *  header would be truncated by the length prefix into something no receiver can parse. Shed
     *  the folder first (the file still arrives, flat), then shorten the name. */
    private fun fitted(header: JSONObject): JSONObject {
      fun size() = header.toString().toByteArray(Charsets.UTF_8).size
      if (size() <= MAX_HEADER_BYTES) return header
      header.remove("dir")
      if (size() <= MAX_HEADER_BYTES) return header
      var name = header.optString("name")
      while (size() > MAX_HEADER_BYTES && name.length > 16) {
        name = name.take(name.length / 2)
        // Don't leave half a surrogate pair at the cut.
        if (name.last().isHighSurrogate()) name = name.dropLast(1)
        header.put("name", name)
      }
      return header
    }

    /** Build a zero-byte [OP_ACK] frame for one stored chunk. */
    fun ack(id: String, seq: Int): ByteArray {
      val header = JSONObject().put("op", OP_ACK).put("id", id).put("seq", seq)
      val headerBytes = header.toString().toByteArray(Charsets.UTF_8)
      val out = ByteArrayOutputStream(2 + headerBytes.size)
      out.write((headerBytes.size shr 8) and 0xFF)
      out.write(headerBytes.size and 0xFF)
      out.write(headerBytes)
      return out.toByteArray()
    }

    /** Build a zero-byte [OP_NACK] frame for one chunk that could not be stored. */
    fun nack(id: String, seq: Int, reason: String? = null): ByteArray {
      val header = JSONObject().put("op", OP_NACK).put("id", id).put("seq", seq)
      if (reason != null) header.put("err", reason.take(200))
      val headerBytes = header.toString().toByteArray(Charsets.UTF_8)
      val out = ByteArrayOutputStream(2 + headerBytes.size)
      out.write((headerBytes.size shr 8) and 0xFF)
      out.write(headerBytes.size and 0xFF)
      out.write(headerBytes)
      return out.toByteArray()
    }

    /** Split an inbound plaintext back into header + raw bytes. null when malformed. */
    fun parse(payload: ByteArray): FileFrame? {
      if (payload.size < 2) return null
      val headerLen = ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF)
      if (payload.size < 2 + headerLen) return null
      val header = try {
        JSONObject(String(payload, 2, headerLen, Charsets.UTF_8))
      } catch (e: Exception) {
        return null
      }
      return FileFrame(
        op = header.optString("op", OP_DATA),
        mime = header.optString("mime", "image/png"),
        name = header.optString("name").ifEmpty { null },
        dir = header.optString("dir").ifEmpty { null },
        disp = header.optString("disp", DISP_CLIP),
        id = header.optString("id").ifEmpty { null },
        seq = header.optInt("seq", 0),
        count = header.optInt("n", 1),
        bytes = payload.copyOfRange(2 + headerLen, payload.size),
        reason = header.optString("err").ifEmpty { null },
      )
    }
  }
}
