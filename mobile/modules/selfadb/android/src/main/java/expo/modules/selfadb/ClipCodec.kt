package expo.modules.selfadb

import android.util.Base64
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.abs

/**
 * End-to-end frame encryption. ChaCha20-Poly1305 (RFC 8439) keyed by the 32-byte pairing
 * key (the secret scanned from the Mac's QR, base64 of 32 random bytes). Wire shape:
 *   nonce = base64(12-byte random nonce),  ct = base64(ciphertext || 16-byte Poly1305 tag).
 *
 * **v2 envelope (replay protection + type binding):**
 *   AAD       = utf8(frame type: "clip" | "cmd" | "stat" | "note" | "sms")
 *   plaintext = 8-byte big-endian epoch-milliseconds || utf8(payload)
 * The AAD stops a captured ciphertext from being relabeled to another frame type; the
 * timestamp (±2 min window) plus a seen-nonce cache stops replays — the relay is an
 * explicitly untrusted pipe.
 *
 * **Transitional:** decode falls back to the legacy v1 format (no AAD, raw payload) so a
 * not-yet-updated peer keeps working; remove the fallback once both ends ship v2.
 *
 * Wire-compatible with the Mac ClipCodec (CryptoKit ChaChaPoly) — the envelope is a
 * byte-exact cross-language contract, change both sides together. Fails closed: malformed
 * key, tampered/relabeled/stale/replayed frame, or key mismatch returns null.
 */
object ClipCodec {
  private val rng = SecureRandom()
  private const val NONCE_LEN = 12
  private const val TAG_LEN = 16
  private const val TS_LEN = 8
  private const val TRANSFORM = "ChaCha20-Poly1305"

  /** Freshness window (ms): frames whose timestamp differs from the local clock by more
   *  than this (either direction, tolerating skew) are rejected as replayed/stale. */
  private const val FRESHNESS_WINDOW_MS = 120_000L

  /** Nonces accepted within the freshness window (`nonceB64 -> tsMs`); a duplicate is a replay. */
  private val seenNonces = HashMap<String, Long>()

  /** Encrypt [text] as a [type] frame. @return (nonce, ct) both base64, or null on a bad key. */
  fun encode(text: String, keyBase64: String, type: String): Pair<String, String>? {
    val key = secretKey(keyBase64) ?: return null
    return try {
      val nonce = ByteArray(NONCE_LEN).also { rng.nextBytes(it) }
      val cipher = Cipher.getInstance(TRANSFORM)
      cipher.init(Cipher.ENCRYPT_MODE, key, IvParameterSpec(nonce))
      cipher.updateAAD(type.toByteArray(Charsets.UTF_8))
      val payload = text.toByteArray(Charsets.UTF_8)
      val plain = ByteBuffer.allocate(TS_LEN + payload.size)
        .putLong(System.currentTimeMillis())
        .put(payload)
        .array()
      val ct = cipher.doFinal(plain) // ciphertext || tag
      Pair(
        Base64.encodeToString(nonce, Base64.NO_WRAP),
        Base64.encodeToString(ct, Base64.NO_WRAP),
      )
    } catch (e: Exception) {
      null
    }
  }

  /** Decrypt a [type] frame to its payload, or null on auth failure / relabeled type /
   *  stale timestamp / replayed nonce / malformed input / wrong key. */
  fun decode(nonce: String, ct: String, keyBase64: String, type: String): String? {
    val key = secretKey(keyBase64) ?: return null
    return try {
      val nonceBytes = Base64.decode(nonce, Base64.DEFAULT)
      val ctBytes = Base64.decode(ct, Base64.DEFAULT)
      if (nonceBytes.size != NONCE_LEN || ctBytes.size < TAG_LEN) return null
      // A v2 frame that authenticates but is stale/replayed is rejected inside openV2; the
      // v1 fallback can't resurrect it (its tag was computed WITH the AAD, so the AAD-less
      // open fails authentication).
      openV2(nonceBytes, ctBytes, key, type, nonce) ?: openV1(nonceBytes, ctBytes, key, type)
    } catch (e: Exception) {
      null
    }
  }

  private fun openV2(
    nonceBytes: ByteArray,
    ctBytes: ByteArray,
    key: SecretKeySpec,
    type: String,
    nonceB64: String,
  ): String? = try {
    val cipher = Cipher.getInstance(TRANSFORM)
    cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(nonceBytes))
    cipher.updateAAD(type.toByteArray(Charsets.UTF_8))
    val plain = cipher.doFinal(ctBytes)
    if (plain.size < TS_LEN) {
      null
    } else {
      val ts = ByteBuffer.wrap(plain).long
      val now = System.currentTimeMillis()
      when {
        abs(now - ts) > FRESHNESS_WINDOW_MS -> null // stale or far-future -> replay/skew
        !rememberNonce(nonceB64, ts, now) -> null // duplicate nonce -> replay
        else -> String(plain, TS_LEN, plain.size - TS_LEN, Charsets.UTF_8)
      }
    }
  } catch (e: Exception) {
    null
  }

  /** Legacy v1 (no AAD, raw payload). Transitional — remove once both ends ship v2. */
  private fun openV1(
    nonceBytes: ByteArray,
    ctBytes: ByteArray,
    key: SecretKeySpec,
    type: String,
  ): String? = try {
    val cipher = Cipher.getInstance(TRANSFORM)
    cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(nonceBytes))
    val plain = String(cipher.doFinal(ctBytes), Charsets.UTF_8)
    ClipBus.log("codec: legacy v1 frame accepted ($type) — update the peer")
    plain
  } catch (e: Exception) {
    null
  }

  /** Records the nonce; false when it was already seen inside the window (a replay). */
  @Synchronized
  private fun rememberNonce(nonce: String, ts: Long, now: Long): Boolean {
    val cutoff = now - FRESHNESS_WINDOW_MS * 2
    seenNonces.entries.removeAll { it.value < cutoff }
    if (seenNonces.containsKey(nonce)) return false
    seenNonces[nonce] = ts
    return true
  }

  private fun secretKey(keyBase64: String): SecretKeySpec? = try {
    val raw = Base64.decode(keyBase64, Base64.DEFAULT)
    if (raw.size != 32) null else SecretKeySpec(raw, "ChaCha20")
  } catch (e: Exception) {
    null
  }
}
