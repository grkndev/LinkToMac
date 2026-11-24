package expo.modules.selfadb.quic

import expo.modules.selfadb.FileFrame

/**
 * Which path ONE file takes (stage 2.1 of `docs/plans/2026-11-14-quic-data-plane.md`, Faz 2): a QUIC stream, the existing WebSocket `file` path
 * (TECHNICAL.md §5.4, limit 1 GiB), a wait for the LAN, or "too large". One pure function, so the rule lives in one place; the Mac's twin is
 * `FileTransportChoice.swift` and both run `protocol-vectors/quic-control.json` (section `transport`, the full cross product). Plain Kotlin.
 *
 * Rules, first match wins:
 *  1. a clipboard image is [WS] whatever its size (one frame; `fitImage` makes it fit);
 *  2. the LAN-direct link and a peer that announced `q1` is [QUIC] (no size limit, also when the size is not known yet);
 *  3. a size that is not known is [WS] (that path applies its own limit while it reads, as it always did);
 *  4. a size up to and including the WebSocket limit is [WS];
 *  5. above it: the relay with a `q1` peer is [WAIT_FOR_LAN] (QUIC will carry it once both are on the same LAN);
 *  6. above it, anything else is [TOO_LARGE] (an older peer cannot do QUIC, so waiting for the LAN would not help).
 */
enum class FileTransportChoice(val logWord: String) {
  QUIC("quic"),
  WS("ws"),
  WAIT_FOR_LAN("wait-for-lan"),
  TOO_LARGE("too-large");

  /** The link the file would travel on right now (the caller does not ask when there is no link at all). */
  enum class Link { LAN, RELAY }

  /** What the call sites act on while QUIC files are not served yet: a [QUIC] verdict still goes over the WebSocket path. */
  val effective: FileTransportChoice
    get() = if (this == QUIC && !QUIC_FILES_SERVED) WS else this

  companion object {
    /** Flipped to `true` in stage 2.5, when a QUIC file stream exists. */
    const val QUIC_FILES_SERVED = false

    /** `size` null (or negative) = not known. The limit is the WebSocket path's own constant, so there is no second "1 GiB" to drift. */
    fun choose(link: Link, peerCaps: Set<String>, size: Long?, isClipboardImage: Boolean): FileTransportChoice {
      if (isClipboardImage) return WS
      val peerQuic = QuicCaps.Q1 in peerCaps
      if (link == Link.LAN && peerQuic) return QUIC
      if (size == null || size < 0) return WS
      if (size <= FileFrame.MAX_TRANSFER_BYTES.toLong()) return WS
      return if (link == Link.RELAY && peerQuic) WAIT_FOR_LAN else TOO_LARGE
    }
  }
}
