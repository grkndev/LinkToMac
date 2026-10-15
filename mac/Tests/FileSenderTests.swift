import Foundation
import Testing

/// A stand-in for the phone: records every frame the sender emits and answers per `behavior`.
private final class FakePhone: @unchecked Sendable {
    enum Behavior {
        case acks                  // ack every chunk immediately
        case silent                // never answer
        case nack(onSeq: Int, String)
        case noLink                // no transport available
        case acksWithHave(Int)     // ack every chunk, reporting `have` (resume)
    }

    private let lock = NSLock()
    private var _frames: [FileFrame.Parsed] = []
    var behavior: Behavior
    /// Per-frame latency, so a test can still be mid-batch when it queues more work.
    var delay: TimeInterval = 0
    weak var sender: FileSender?

    init(_ behavior: Behavior) { self.behavior = behavior }

    var frames: [FileFrame.Parsed] { lock.lock(); defer { lock.unlock() }; return _frames }

    lazy var transport: FileSender.Transport = { [unowned self] payload in
        guard let frame = FileFrame.parse(payload) else { return nil }
        lock.lock(); _frames.append(frame); lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch behavior {
        case .acks:
            if let id = frame.id { sender?.ack(id: id, seq: frame.seq) }
        case let .acksWithHave(have):
            if let id = frame.id { sender?.ack(id: id, seq: frame.seq, have: have) }
        case .silent:
            break
        case let .nack(seq, reason):
            if let id = frame.id {
                if frame.seq == seq { sender?.nack(id: id, reason: reason) } else { sender?.ack(id: id, seq: frame.seq) }
            }
        case .noLink:
            return nil
        }
        return .lan
    }
}

private func config(timeout: TimeInterval = 0.4) -> FileSender.Config {
    var c = FileSender.Config()
    c.chunkBytes = 4
    c.ackTimeout = timeout
    c.relayChunkInterval = 0
    return c
}

private func makeFile(_ bytes: Int, name: String = "f.bin", in dir: URL) throws -> OutgoingItem {
    let url = dir.appendingPathComponent(name)
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    return OutgoingItem(url: url, name: name, dir: nil, size: bytes)
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func run(_ sender: FileSender, _ items: [OutgoingItem], _ phone: FakePhone) async -> BatchResult {
    phone.sender = sender
    return await withCheckedContinuation { cont in
        sender.send(items: items, transport: phone.transport, progress: { _ in }, done: { cont.resume(returning: $0) })
    }
}

@Suite struct FileSenderTests {
    @Test func smallFileIsAckedAndReportedSent() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(3, in: dir) // under one chunk
        let phone = FakePhone(.acks)
        let result = await run(FileSender(config: config()), [item], phone)

        #expect(result.sent == ["f.bin"])
        #expect(result.failures.isEmpty)
        #expect(phone.frames.count == 1)
        #expect(phone.frames[0].id != nil) // the id is what makes the phone ack at all
        #expect(phone.frames[0].disp == FileFrame.dispSave)
    }

    @Test func chunksArriveInOrderAndReassemble() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(10, in: dir) // 4 + 4 + 2
        let phone = FakePhone(.acks)
        let result = await run(FileSender(config: config()), [item], phone)

        #expect(result.sent.count == 1)
        #expect(phone.frames.map(\.seq) == [0, 1, 2])
        #expect(phone.frames.allSatisfy { $0.count == 3 })
        let rebuilt = phone.frames.reduce(Data()) { $0 + $1.bytes }
        #expect(rebuilt == (try Data(contentsOf: item.url)))
    }

    @Test func folderPathRidesOnEveryChunk() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var item = try makeFile(9, in: dir)
        item = OutgoingItem(url: item.url, name: item.name, dir: "Album/Sub", size: item.size)
        let phone = FakePhone(.acks)
        _ = await run(FileSender(config: config()), [item], phone)
        #expect(phone.frames.allSatisfy { $0.dir == "Album/Sub" })
    }

    @Test func silentPhoneTimesOutAndTheNextSendDoesNotCrash() async throws {
        // The crash, end to end: a transfer that ends short of its acks, then another.
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(3, in: dir)
        let sender = FileSender(config: config(timeout: 0.1))

        let first = await run(sender, [item], FakePhone(.silent))
        #expect(first.sent.isEmpty)
        #expect(first.failures.first?.reason == "Your phone stopped responding")

        let second = await run(sender, [item], FakePhone(.acks))
        #expect(second.sent == ["f.bin"])
    }

    @Test func nackFailsFastWithThePhonesReasonAndTheBatchContinues() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile(12, name: "a.bin", in: dir)
        let b = try makeFile(3, name: "b.bin", in: dir)
        let phone = FakePhone(.nack(onSeq: 1, "Storage full"))
        let started = Date()
        let result = await run(FileSender(config: config(timeout: 5)), [a, b], phone)

        #expect(Date().timeIntervalSince(started) < 3) // did not sit out the 5 s timeout
        #expect(result.failures == [.init(name: "a.bin", reason: "Storage full")])
        // b has a single chunk (seq 0), which the fake acks, so a refused file is not fatal.
        #expect(result.sent == ["b.bin"])
    }

    @Test func lostLinkEndsTheBatchAtOnce() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = [try makeFile(3, name: "a", in: dir), try makeFile(3, name: "b", in: dir)]
        let started = Date()
        let result = await run(FileSender(config: config(timeout: 5)), items, FakePhone(.noLink))

        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.reason == "Lost the connection to your phone")
        #expect(result.notSent == 1) // b was never attempted: the link is gone for it too
    }

    @Test func filesInABatchGoOneAfterAnother() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = [try makeFile(5, name: "a", in: dir), try makeFile(5, name: "b", in: dir), try makeFile(5, name: "c", in: dir)]
        let phone = FakePhone(.acks)
        let result = await run(FileSender(config: config()), items, phone)

        #expect(result.sent == ["a", "b", "c"])
        #expect(phone.frames.compactMap(\.name) == ["a", "a", "b", "b", "c", "c"])
    }

    @Test func aDropMidBatchJoinsIt() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeFile(40, name: "first", in: dir)
        let late = try makeFile(3, name: "late", in: dir)
        let sender = FileSender(config: config())
        let phone = FakePhone(.acks)
        phone.delay = 0.01 // 10 chunks ≈ 100 ms: ample time for the second send to land mid-batch
        phone.sender = sender

        let result: BatchResult = await withCheckedContinuation { cont in
            sender.send(items: [first], transport: phone.transport, progress: { _ in },
                        done: { cont.resume(returning: $0) })
            sender.send(items: [late], transport: phone.transport, progress: { _ in }, done: { _ in
                Issue.record("a joined drop must not start its own batch")
            })
        }
        #expect(result.sent == ["first", "late"])
    }

    @Test func cancelStopsTheBatch() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = [try makeFile(40, name: "a", in: dir), try makeFile(40, name: "b", in: dir)]
        let sender = FileSender(config: config(timeout: 5))
        let phone = FakePhone(.silent)
        phone.sender = sender

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { sender.cancel() }
        let started = Date()
        let result: BatchResult = await withCheckedContinuation { cont in
            sender.send(items: items, transport: phone.transport, progress: { _ in }, done: { cont.resume(returning: $0) })
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.cancelled)
        #expect(result.sent.isEmpty)
        #expect(result.failures.isEmpty) // cancelling is not a failure
        #expect(!sender.isBusy)
    }

    @Test func progressTracksBytesAcrossTheBatch() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = [try makeFile(8, name: "a", in: dir), try makeFile(8, name: "b", in: dir)]
        let sender = FileSender(config: config())
        let phone = FakePhone(.acks)
        phone.sender = sender
        let seen = Locked<[BatchProgress]>([])

        _ = await withCheckedContinuation { (cont: CheckedContinuation<BatchResult, Never>) in
            sender.send(items: items, transport: phone.transport,
                        progress: { p in seen.mutate { $0.append(p) } }, done: { cont.resume(returning: $0) })
        }
        let all = seen.value
        #expect(all.last?.overallFraction == 1 || all.last?.doneBytes == 16)
        #expect(all.allSatisfy { $0.totalBytes == 16 && $0.count == 2 })
        // The bar only ever moves forward.
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.doneBytes <= $1.doneBytes })
        #expect(all.contains { $0.index == 2 })
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

@Suite struct FileSenderResumeTests {
    @Test func theAcksHaveSkipsTheChunksThePhoneAlreadyHolds() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(40, in: dir) // 10 chunks of 4 bytes
        let phone = FakePhone(.acksWithHave(6))
        let result = await run(FileSender(config: config()), [item], phone)

        #expect(result.sent == ["f.bin"])
        // Chunk 0 goes out, its ack says "I have 0..<6", so the sender jumps straight to chunk 6.
        #expect(phone.frames.map(\.seq) == [0, 6, 7, 8, 9])
        let tail = phone.frames.dropFirst().reduce(Data()) { $0 + $1.bytes }
        #expect(tail == (try Data(contentsOf: item.url)).suffix(16))
    }

    @Test func aHaveBeyondTheEndStillSendsTheLastChunk() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(40, in: dir)
        let phone = FakePhone(.acksWithHave(9999))
        let result = await run(FileSender(config: config()), [item], phone)

        #expect(result.sent == ["f.bin"])
        // Clamped: the last chunk must still go, because it is what completes the file.
        #expect(phone.frames.map(\.seq) == [0, 9])
    }

    @Test func resumeProgressCountsSkippedBytesAsDone() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let item = try makeFile(40, in: dir)
        let sender = FileSender(config: config())
        let phone = FakePhone(.acksWithHave(6))
        phone.sender = sender
        let seen = Locked<[BatchProgress]>([])
        _ = await withCheckedContinuation { (cont: CheckedContinuation<BatchResult, Never>) in
            sender.send(items: [item], transport: phone.transport,
                        progress: { p in seen.mutate { $0.append(p) } }, done: { cont.resume(returning: $0) })
        }
        let all = seen.value
        #expect(all.contains { $0.currentDone == 24 }) // 6 chunks × 4 bytes jumped over
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.currentDone <= $1.currentDone })
        #expect(all.last?.currentDone == 40)
    }

    @Test func theTransferIDIsStableForTheSameFileAndChangesWhenItIsEdited() {
        let url = URL(fileURLWithPath: "/tmp/a.bin")
        let base = OutgoingItem(url: url, name: "a.bin", dir: "Trip", size: 100, mtime: 1_000)
        let again = OutgoingItem(url: URL(fileURLWithPath: "/elsewhere/a.bin"), name: "a.bin", dir: "Trip", size: 100, mtime: 1_000)
        #expect(FileSender.transferID(for: base) == FileSender.transferID(for: again)) // same file, same id
        #expect(FileSender.transferID(for: base).count == 8)
        #expect(FileSender.transferID(for: base) != FileSender.transferID(for: OutgoingItem(url: url, name: "a.bin", dir: "Trip", size: 101, mtime: 1_000)))
        #expect(FileSender.transferID(for: base) != FileSender.transferID(for: OutgoingItem(url: url, name: "a.bin", dir: "Trip", size: 100, mtime: 1_001)))
        #expect(FileSender.transferID(for: base) != FileSender.transferID(for: OutgoingItem(url: url, name: "a.bin", dir: nil, size: 100, mtime: 1_000)))
    }
}

@Suite struct BatchProgressTests {
    @Test func labelNamesTheFileWithItsOwnPercent() {
        let p = BatchProgress(currentName: "rapor.pdf", currentDone: 50, currentTotal: 100, index: 2, count: 5,
                              doneBytes: 150, totalBytes: 1000)
        #expect(p.label == "rapor.pdf (50%)")
        #expect(p.overallFraction == 0.15)
    }

    @Test func emptyTotalsDoNotDivideByZero() {
        let p = BatchProgress.starting(name: "x")
        #expect(p.overallFraction == 0)
        #expect(p.label == "x (0%)")
    }
}
