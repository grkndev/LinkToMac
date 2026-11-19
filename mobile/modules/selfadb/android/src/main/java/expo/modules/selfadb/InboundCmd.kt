package expo.modules.selfadb

import org.json.JSONObject

/**
 * What the phone does with a `cmd` frame from the Mac (QUIC plan stage 1.2). `cmd` used to travel phone -> Mac only; the Mac
 * now sends it too (stage 1.1), carrying either a plain action string or a `q.*` JSON object that opens or closes a QUIC session.
 *
 * Plain Kotlin on purpose (no Android types beyond what [ClipCodec] needs), so the decisions run in JVM unit tests. Both the
 * relay client and the LAN client call [open], which keeps the AAD frame type in one place; the service decides with
 * [classify] / [route].
 */
object InboundCmd {
  /** What an opened action turns out to be. */
  enum class Kind {
    /** Starts with `{`: a `q.*` object for the dispatcher (stage 1.3). */
    JSON,

    /** A plain string the phone has no handler for. Nothing is defined in the Mac -> phone direction today. */
    UNKNOWN,

    /** Nothing in it. */
    EMPTY,
  }

  /**
   * Opens a `{"t":"cmd","nonce","ct"}` frame. Returns the action, or null for anything that is not an authentic, fresh, first-time
   * `cmd`: wrong key, relabelled type, stale or future timestamp, replayed nonce, missing or malformed fields. Never throws
   * ([ClipCodec] turns every failure into null), so a bad frame from the network cannot take the receive loop down.
   */
  fun open(frame: JSONObject, key: String): String? =
    ClipCodec.decode(frame.optString("nonce"), frame.optString("ct"), key, "cmd")

  /** Only the first character decides: an action with leading whitespace is not an object. */
  fun classify(action: String): Kind = when {
    action.isEmpty() -> Kind.EMPTY
    action[0] == '{' -> Kind.JSON
    else -> Kind.UNKNOWN
  }

  /**
   * Hands a JSON action to [onJson] exactly once; anything else goes to [onIgnored] with its kind and **length only**: the
   * action text itself never reaches a log (it can carry a session id, port or token).
   */
  fun route(action: String, onJson: (String) -> Unit, onIgnored: (kind: Kind, length: Int) -> Unit) {
    val kind = classify(action)
    if (kind == Kind.JSON) onJson(action) else onIgnored(kind, action.length)
  }
}
