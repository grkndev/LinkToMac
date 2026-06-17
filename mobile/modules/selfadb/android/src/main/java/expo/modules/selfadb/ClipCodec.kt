package expo.modules.selfadb

import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end clipboard encryption. ChaCha20-Poly1305 (RFC 8439) keyed by the 32-byte pairing
 * key (the secret scanned from the Mac's QR, base64 of 32 random bytes). Wire shape:
 *   nonce = base64(12-byte random nonce),  ct = base64(ciphertext || 16-byte Poly1305 tag).
 * Wire-compatible with the Mac ClipCodec (CryptoKit ChaChaPoly). The relay only ever sees opaque
 * base64 — never the key or the plaintext. Fails closed: a malformed key, a tampered frame, or a
 * key mismatch returns null and the clip is dropped.
 */
object ClipCodec {
  private val rng = SecureRandom()
  private const val NONCE_LEN = 12
  private const val TAG_LEN = 16
  private const val TRANSFORM = "ChaCha20-Poly1305"

  /** @return (nonce, ct) both base64, or null if [keyBase64] is malformed. */
  fun encode(text: String, keyBase64: String): Pair<String, String>? {
    val key = secretKey(keyBase64) ?: return null
    return try {
      val nonce = ByteArray(NONCE_LEN).also { rng.nextBytes(it) }
      val cipher = Cipher.getInstance(TRANSFORM)
      cipher.init(Cipher.ENCRYPT_MODE, key, IvParameterSpec(nonce))
      val ct = cipher.doFinal(text.toByteArray(Charsets.UTF_8)) // ciphertext || tag
      Pair(
        Base64.encodeToString(nonce, Base64.NO_WRAP),
        Base64.encodeToString(ct, Base64.NO_WRAP),
      )
    } catch (e: Exception) {
      null
    }
  }

  /** Decrypt to plaintext, or null on auth failure / malformed input / wrong key. */
  fun decode(nonce: String, ct: String, keyBase64: String): String? {
    val key = secretKey(keyBase64) ?: return null
    return try {
      val nonceBytes = Base64.decode(nonce, Base64.DEFAULT)
      val ctBytes = Base64.decode(ct, Base64.DEFAULT)
      if (nonceBytes.size != NONCE_LEN || ctBytes.size < TAG_LEN) return null
      val cipher = Cipher.getInstance(TRANSFORM)
      cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(nonceBytes))
      String(cipher.doFinal(ctBytes), Charsets.UTF_8)
    } catch (e: Exception) {
      null
    }
  }

  private fun secretKey(keyBase64: String): SecretKeySpec? = try {
    val raw = Base64.decode(keyBase64, Base64.DEFAULT)
    if (raw.size != 32) null else SecretKeySpec(raw, "ChaCha20")
  } catch (e: Exception) {
    null
  }
}
