package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderWalkerTest {
  /** A fake provider: folder id -> its children. */
  private class FakeTree(private val kids: Map<String, List<Doc>>) : DocTree {
    override fun children(parentId: String): List<Doc> = kids[parentId].orEmpty()
  }

  private fun file(name: String, size: Long = 10) = Doc("f-$name", name, false, size, "x/y", 0)
  private fun folder(name: String) = Doc("d-$name", name, true, 0, "vnd.android.document/directory", 0)

  @Test fun keepsEachFilesFolderPathIncludingTheRoot() {
    val tree = FakeTree(mapOf(
      "root" to listOf(file("a.txt"), folder("Sub")),
      "d-Sub" to listOf(file("b.txt"), folder("Deep")),
      "d-Deep" to listOf(file("c.txt")),
    ))
    val walk = FolderWalker.walk(tree, "root", "Album")
    val byName = walk.files.associate { it.doc.name to it.dir }
    assertEquals("Album", byName["a.txt"])
    assertEquals("Album/Sub", byName["b.txt"])
    assertEquals("Album/Sub/Deep", byName["c.txt"])
    assertTrue(walk.problems.isEmpty())
  }

  @Test fun skipsHiddenFilesAndFolders() {
    val tree = FakeTree(mapOf(
      "root" to listOf(file("keep.txt"), file(".secret"), folder(".git"), folder("ok")),
      "d-.git" to listOf(file("config")),
      "d-ok" to listOf(file("inside.txt")),
    ))
    val names = FolderWalker.walk(tree, "root", "R").files.map { it.doc.name }
    assertEquals(listOf("inside.txt", "keep.txt"), names.sorted())
  }

  @Test fun orderIsStableByName() {
    val tree = FakeTree(mapOf("root" to listOf(file("b"), file("C"), file("a"))))
    assertEquals(listOf("a", "b", "C"), FolderWalker.walk(tree, "root", "R").files.map { it.doc.name })
  }

  @Test fun emptyAndOversizedFilesAreReportedNotDropped() {
    val tree = FakeTree(mapOf("root" to listOf(file("zero", 0), file("big", 2000), file("fine", 5))))
    val walk = FolderWalker.walk(tree, "root", "R", maxBytes = 1000)
    assertEquals(listOf("fine"), walk.files.map { it.doc.name })
    assertTrue(walk.problems.contains("zero is empty"))
    assertTrue(walk.problems.any { it.startsWith("big is larger than") })
  }

  @Test fun anEmptyFolderIsReported() {
    val walk = FolderWalker.walk(FakeTree(emptyMap()), "root", "Nothing")
    assertTrue(walk.files.isEmpty())
    assertEquals(listOf("Nothing has no files to send"), walk.problems)
  }

  @Test fun aRunawayFolderIsCapped() {
    val many = (1..12).map { file("f$it") }
    val walk = FolderWalker.walk(FakeTree(mapOf("root" to many)), "root", "Big", maxFiles = 10)
    assertEquals(10, walk.files.size)
    assertTrue(walk.problems.any { it.contains("only the first 10 files") })
  }

  @Test fun aCyclicProviderCannotSpinTheWalk() {
    // "d-loop" lists itself as a child forever; the depth cap ends it.
    val tree = FakeTree(mapOf("root" to listOf(folder("loop")), "d-loop" to listOf(folder("loop"), file("x"))))
    val walk = FolderWalker.walk(tree, "root", "R")
    assertTrue(walk.problems.any { it.contains("nested too deep") })
  }
}
