package expo.modules.selfadb

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * `stat.lan`, the Mac's LAN address hint: runs the `parse` cases of `protocol-vectors/stat-lan.json`; the Mac's `StatLanVectorTests` runs the
 * same cases (and, alone, the `pick` cases that decide what the Mac writes).
 */
class StatLanVectorTest {
  private fun cases(section: String): List<JSONObject> {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    val all: JSONArray = JSONObject(File(dir, "stat-lan.json").readText()).getJSONObject(section).getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }
  }

  @Test fun theVectorFileHasTheCasesThisSuiteRuns() {
    assertTrue(cases("parse").size >= 40)
    assertTrue(cases("pick").isNotEmpty())
  }

  @Test fun parseVectors() {
    for (c in cases("parse")) {
      val expect = c.getJSONObject("expect")
      val update = StatLan.parse(c.getJSONObject("stat"))
      when (expect.getString("update")) {
        "absent" -> assertEquals(c.getString("name"), StatLan.Update.Absent, update)
        "hints" -> {
          val want = expect.getJSONArray("hints").let { a -> (0 until a.length()).map { a.getString(it) } }
          val got = (update as? StatLan.Update.Hints)?.hints?.map { "${it.host}:${it.port}" }
          assertEquals(c.getString("name"), want, got)
        }
        else -> throw AssertionError("${c.getString("name")}: unknown expected update")
      }
    }
  }
}
