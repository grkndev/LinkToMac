package expo.modules.selfadb

import android.util.Base64
import java.security.SecureRandom

/**
 * Placeholder clip codec, mirroring mobile/src/features/relay/clip-codec.ts and the Mac
 * ClipCodec.swift. NO ENCRYPTION YET — `ct` is base64(utf8(text)), `nonce` is random
 * filler so the wire shape matches. libsodium secretbox replaces this later; only this
 * file (and its Mac/JS twins) changes.
 */
object ClipCodec {
  private val rng = SecureRandom()

  /** @return (nonce, ct) both standard base64. */
  fun encode(text: String): Pair<String, String> {
    val nonce = ByteArray(24).also { rng.nextBytes(it) }
    return Pair(
      Base64.encodeToString(nonce, Base64.NO_WRAP),
      Base64.encodeToString(text.toByteArray(Charsets.UTF_8), Base64.NO_WRAP),
    )
  }

  fun decode(ct: String): String? = try {
    String(Base64.decode(ct, Base64.DEFAULT), Charsets.UTF_8)
  } catch (e: Exception) {
    null
  }
}
