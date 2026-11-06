package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class AppUpdateTest {
  @get:Rule val tmp = TemporaryFolder()

  private val sha = "a".repeat(64)

  @Test fun comparesVersions() {
    assertTrue(UpdateLogic.compareVersions("0.12.0", "0.11.0") > 0)
    assertTrue(UpdateLogic.compareVersions("0.11.0", "0.12.0") < 0)
    assertEquals(0, UpdateLogic.compareVersions("v0.12.0", "0.12.0"))
    assertEquals(0, UpdateLogic.compareVersions("0.2", "0.2.0")) // differing segment counts
    assertTrue(UpdateLogic.compareVersions("0.10.0", "0.9.0") > 0) // numeric, not lexical
    assertTrue(UpdateLogic.compareVersions("1.0.0", "0.99.99") > 0)
    assertEquals(0, UpdateLogic.compareVersions("0.12.0-beta", "0.12.0")) // suffix ignored
  }

  @Test fun parsesAReleaseWithAnApk() {
    val r = UpdateLogic.parseRelease(
      """{"tag_name":"v0.12.0","body":" notes ","html_url":"https://github.com/x/releases/v0.12.0",
         "assets":[{"name":"mac.dmg","browser_download_url":"https://x/mac.dmg","size":1},
                   {"name":"LinkToMac-0.12.0.APK","browser_download_url":"https://x/app.apk","size":12345,
                    "digest":"sha256:${sha.uppercase()}"}]}""",
    )!!
    assertEquals("0.12.0", r.version)
    assertEquals("notes", r.notes)
    assertEquals("https://x/app.apk", r.apkUrl) // the apk, not the dmg
    assertEquals(12345L, r.apkSize)
    assertEquals(sha, r.sha256) // normalised to lower case
    assertEquals("https://github.com/x/releases/v0.12.0", r.pageUrl)
  }

  @Test fun parsesAReleaseWithoutApkOrDigest() {
    val noApk = UpdateLogic.parseRelease("""{"tag_name":"v1.0.0","html_url":"https://x/r","assets":[]}""")!!
    assertNull(noApk.apkUrl)
    assertNull(noApk.notes)
    val noDigest = UpdateLogic.parseRelease(
      """{"tag_name":"1.0.0","assets":[{"name":"a.apk","browser_download_url":"https://x/a.apk","size":9}]}""",
    )!!
    assertEquals("1.0.0", noDigest.version)
    assertNull(noDigest.sha256)
  }

  @Test fun rejectsAPayloadWithoutAVersion() {
    assertNull(UpdateLogic.parseRelease("""{"assets":[]}"""))
    assertNull(UpdateLogic.parseRelease("not json"))
  }

  @Test fun onlyAcceptsAWellFormedSha256Digest() {
    assertEquals(sha, UpdateLogic.parseDigest("sha256:$sha"))
    assertNull(UpdateLogic.parseDigest("sha1:$sha"))
    assertNull(UpdateLogic.parseDigest("sha256:zz"))
    assertNull(UpdateLogic.parseDigest("sha256:${"a".repeat(63)}"))
  }

  @Test fun hashesAFile() {
    val f = File(tmp.root, "x.bin").apply { writeText("abc") }
    // Well-known SHA-256("abc").
    assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", UpdateLogic.sha256Hex(f))
  }

  @Test fun resumesAPartialFileButNotAStaleOne() {
    val part = File(tmp.root, "a.apk.part")
    assertEquals(0L, UpdateLogic.resumeOffset(part, 100)) // nothing yet
    part.writeBytes(ByteArray(40))
    assertEquals(40L, UpdateLogic.resumeOffset(part, 100))
    assertEquals(40L, UpdateLogic.resumeOffset(part, 0)) // unknown total: trust what's on disk
    part.writeBytes(ByteArray(100))
    assertEquals(0L, UpdateLogic.resumeOffset(part, 100)) // already "complete" but never promoted: start over
    part.writeBytes(ByteArray(150))
    assertEquals(0L, UpdateLogic.resumeOffset(part, 100)) // bigger than the asset: corrupt
  }

  @Test fun recordSurvivesARoundTrip() {
    val rec = UpdateRecord(
      release = ReleaseInfo("0.13.0", "n", "https://x/r", "https://x/a.apk", 99, sha),
      state = UpdateState.READY,
      progress = 100,
      path = "/cache/updates/0.13.0.apk",
    )
    assertEquals(rec, UpdateRecord.fromJson(rec.toJson()))
    val failed = UpdateRecord(rec.release, UpdateState.FAILED, error = "Signed with a different key", retryable = false)
    assertEquals(failed, UpdateRecord.fromJson(failed.toJson())) // the "don't re-download" flag survives a restart
    assertTrue(UpdateRecord.fromJson("{\"state\":\"FAILED\"}").retryable) // older records default to retryable
    val bare = UpdateRecord(release = null)
    assertEquals(bare, UpdateRecord.fromJson(bare.toJson()))
  }

  @Test fun aBrokenRecordReadsAsEmpty() {
    assertEquals(UpdateRecord(null), UpdateRecord.fromJson("{oops"))
    assertEquals(UpdateRecord(null), UpdateRecord.fromJson(null))
    assertFalse(UpdateRecord.fromJson("").release != null)
  }

  @Test fun mapForJsCarriesTheDownloadableFlag() {
    val withApk = UpdateRecord(ReleaseInfo("1.0.0", null, "https://x/r", "https://x/a.apk", 1, null), UpdateState.DOWNLOADING, 42)
    assertEquals("downloading", withApk.toMap()["state"])
    assertEquals(true, withApk.toMap()["downloadable"])
    assertEquals("https://x/a.apk", withApk.toMap()["url"])
    val pageOnly = UpdateRecord(ReleaseInfo("1.0.0", null, "https://x/r", null, 0, null))
    assertEquals(false, pageOnly.toMap()["downloadable"])
    assertEquals("https://x/r", pageOnly.toMap()["url"])
  }
}
