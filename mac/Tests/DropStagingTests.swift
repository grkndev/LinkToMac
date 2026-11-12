import Foundation
import Testing

@Suite struct DropStagingTests {
    /// Each test gets its own "temp directory", so none of them touches the real staging root.
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A source file like the one an item provider hands to its callback.
    private func source(named name: String, in dir: URL, text: String = "payload") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func eachDropGetsItsOwnFreshFolder() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try DropStaging.makeFolder(base: base)
        let b = try DropStaging.makeFolder(base: base)
        #expect(a != b)
        #expect(a.deletingLastPathComponent() == DropStaging.root(base: base))
        for folder in [a, b] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
        }
    }

    @Test func aStagedFileKeepsItsNameAndContentAndOutlivesTheSource() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(named: "tmp-1234", in: base, text: "hello")
        let folder = try DropStaging.makeFolder(base: base)
        let staged = try DropStaging.stage(copying: src, suggestedName: "invoice.pdf", typeIdentifier: "com.adobe.pdf", into: folder)
        try FileManager.default.removeItem(at: src)   // the provider deletes its temp file after the callback

        #expect(staged.lastPathComponent == "invoice.pdf")
        #expect(staged.deletingLastPathComponent() == folder)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "hello")
    }

    @Test func theSuggestedNameIsTreatedAsUntrusted() {
        let src = URL(fileURLWithPath: "/tmp/ignored.bin")
        #expect(DropStaging.stagedName(suggested: "../../etc/passwd", source: src, typeIdentifier: nil) == "passwd.bin")
        #expect(DropStaging.stagedName(suggested: "a/b:c.txt", source: src, typeIdentifier: nil) == "b-c.txt")
        #expect(DropStaging.stagedName(suggested: "...hidden.txt", source: src, typeIdentifier: nil) == "hidden.txt")
        #expect(DropStaging.stagedName(suggested: "   ", source: URL(fileURLWithPath: "/tmp/real.jpg"), typeIdentifier: nil) == "real.jpg")
        #expect(DropStaging.stagedName(suggested: nil, source: URL(fileURLWithPath: "/"), typeIdentifier: nil) == "Dropped item")
    }

    @Test func aMissingExtensionComesFromTheFileOrTheType() {
        // Photos typically suggests "IMG_0042" with no extension.
        let png = DropStaging.stagedName(suggested: "IMG_0042", source: URL(fileURLWithPath: "/tmp/x"), typeIdentifier: "public.png")
        #expect(png == "IMG_0042.png")
        let fromFile = DropStaging.stagedName(suggested: "IMG_0042", source: URL(fileURLWithPath: "/tmp/x.heic"), typeIdentifier: "public.png")
        #expect(fromFile == "IMG_0042.heic", "the file's own extension wins over the type's")
        #expect(DropStaging.stagedName(suggested: "notes.md", source: URL(fileURLWithPath: "/tmp/x"), typeIdentifier: "public.png") == "notes.md")
    }

    @Test func aVeryLongNameIsCutButKeepsItsExtension() {
        let long = String(repeating: "a", count: 400) + ".pdf"
        let name = DropStaging.stagedName(suggested: long, source: URL(fileURLWithPath: "/tmp/x"), typeIdentifier: nil)
        #expect(name.utf8.count <= 200)
        #expect(name.hasSuffix(".pdf"))
    }

    @Test func twoFilesWithTheSameNameDoNotOverwriteEachOther() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let folder = try DropStaging.makeFolder(base: base)
        let one = try source(named: "s1", in: base, text: "one")
        let two = try source(named: "s2", in: base, text: "two")
        let three = try source(named: "s3", in: base, text: "three")
        let names = try [one, two, three].map {
            try DropStaging.stage(copying: $0, suggestedName: "image.jpg", typeIdentifier: nil, into: folder).lastPathComponent
        }
        #expect(names == ["image.jpg", "image 2.jpg", "image 3.jpg"])
        #expect(try String(contentsOf: folder.appendingPathComponent("image.jpg"), encoding: .utf8) == "one")
    }

    @Test func numberingKeepsTheExtensionAndHandlesNone() {
        #expect(DropStaging.numbered("report.pdf", 2) == "report 2.pdf")
        #expect(DropStaging.numbered("archive.tar.gz", 3) == "archive.tar 3.gz")
        #expect(DropStaging.numbered("README", 2) == "README 2")
    }

    @Test func sweepRemovesOldDropsAndKeepsFreshOnes() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let old = try DropStaging.makeFolder(base: base, now: now)
        let fresh = try DropStaging.makeFolder(base: base, now: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-DropStaging.maxAge - 60)], ofItemAtPath: old.path)

        DropStaging.sweep(base: base, now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func makingAFolderSweepsStaleOnesToo() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let stale = try DropStaging.makeFolder(base: base, now: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-DropStaging.maxAge - 1)], ofItemAtPath: stale.path)
        _ = try DropStaging.makeFolder(base: base, now: now)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func purgeAllClearsEverythingAndToleratesNothingToClear() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try DropStaging.makeFolder(base: base)
        _ = try DropStaging.makeFolder(base: base)
        DropStaging.purgeAll(base: base)
        #expect(!FileManager.default.fileExists(atPath: DropStaging.root(base: base).path))
        DropStaging.purgeAll(base: base)   // nothing there: must not crash
    }

    // The type chooser: which registered type is a promised FILE and which is just a dragged snippet.
    private let promised = ["com.apple.pasteboard.promised-file-url", "com.apple.NSFilePromiseItemMetaData"]

    @Test func aPromisedFilePicksItsContentTypeNotTheBookkeepingOnes() {
        #expect(DropStaging.fileLikeType(among: promised + ["public.jpeg"]) == "public.jpeg")
        #expect(DropStaging.fileLikeType(among: ["com.apple.pasteboard.promised-file-content-type", "com.adobe.pdf"]) == "com.adobe.pdf")
        #expect(DropStaging.fileLikeType(among: promised + ["dyn.ah62d4rv4ge81k4pn", "public.png"]) == "public.png")
        // a zip is data but not "content" — real files must not be cut out by being unusual
        #expect(DropStaging.fileLikeType(among: promised + ["public.zip-archive"]) == "public.zip-archive")
    }

    @Test func withoutPromiseMarkersNothingIsAFile() {
        // Text selections, links and plain dragged images carry no promise markers.
        #expect(DropStaging.fileLikeType(among: ["public.utf8-plain-text", "public.plain-text"]) == nil)
        #expect(DropStaging.fileLikeType(among: ["public.url", "public.url-name"]) == nil)
        #expect(DropStaging.fileLikeType(among: ["public.png"]) == nil, "a bare image drag is not a promise")
        #expect(DropStaging.fileLikeType(among: ["com.apple.webarchive", "public.html"]) == nil)
        #expect(DropStaging.fileLikeType(among: ["public.file-url"]) == nil, "a file URL is handled by the normal path")
        #expect(DropStaging.fileLikeType(among: []) == nil)
    }

    @Test func aLinkTitleOrAURLIsNeverChosenAsTheContent() {
        // On a promise these can only be bookkeeping; the request falls back to the generic type.
        #expect(DropStaging.fileLikeType(among: promised + ["public.url-name", "public.url"]) == "public.data")
        #expect(DropStaging.fileLikeType(among: promised + ["not.a.registered.type"]) == "public.data")
    }

    @Test func markersWithNoConcreteTypeRequestTheGenericDataType() {
        // The shape measured with a real NSFilePromiseProvider: markers and bookkeeping only.
        let measured = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-name",
                        "com.apple.pasteboard.promised-suggested-file-name",
                        "com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.NSFilePromiseID"]
        #expect(DropStaging.fileLikeType(among: measured) == "public.data")
        // …and without markers there is still nothing to ask for.
        #expect(DropStaging.fileLikeType(among: ["com.apple.pasteboard.promised-file-name"]) == nil)
    }

    @Test func aPromisedTextFileIsStillAFile() {
        // An attached notes.txt: its promised content type is text, but it IS a promise.
        #expect(DropStaging.fileLikeType(among: promised + ["public.plain-text"]) == "public.plain-text")
    }
}
