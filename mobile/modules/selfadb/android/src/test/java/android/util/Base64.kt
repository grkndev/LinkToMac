package android.util

/**
 * TEST-ONLY stand-in for android.util.Base64, so the JVM unit tests can run `ClipCodec` (the production class uses the Android
 * one; with `returnDefaultValues = true` the android.jar stub would hand back null and every frame would look undecodable). It
 * lives in the test source set, so it is found before the stub and replaces nothing in the shipped app. (Kotlin, not Java: the
 * repository ignores `*.java` on purpose, see .gitignore.)
 *
 * It is NOT a full copy of Android's behaviour: decoding goes through `java.util.Base64`'s MIME decoder, which ignores characters
 * outside the alphabet like Android's DEFAULT does, but the two are not identical on every malformed input. The tests that use it
 * check the cmd logic, not base64 corner cases.
 */
object Base64 {
  const val DEFAULT = 0
  const val NO_PADDING = 1
  const val NO_WRAP = 2
  const val CRLF = 4
  const val URL_SAFE = 8
  const val NO_CLOSE = 16

  @JvmStatic
  fun decode(str: String, flags: Int): ByteArray = decode(str.toByteArray(Charsets.US_ASCII), flags)

  @JvmStatic
  fun decode(input: ByteArray, flags: Int): ByteArray {
    val decoder = if (flags and URL_SAFE != 0) java.util.Base64.getUrlDecoder() else java.util.Base64.getMimeDecoder()
    return decoder.decode(input)
  }

  @JvmStatic
  fun encode(input: ByteArray, flags: Int): ByteArray {
    var encoder = if (flags and URL_SAFE != 0) java.util.Base64.getUrlEncoder() else java.util.Base64.getEncoder()
    if (flags and NO_PADDING != 0) encoder = encoder.withoutPadding()
    return encoder.encode(input)
  }

  @JvmStatic
  fun encodeToString(input: ByteArray, flags: Int): String = String(encode(input, flags), Charsets.US_ASCII)
}
