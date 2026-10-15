import Foundation
import UniformTypeIdentifiers

// Foundation only on purpose: the sender, the planner and the progress model are pure logic, so
// the unit-test target compiles them without dragging AppKit or a running app along.

/// One transfer in flight, for the progress UI. Deliberately unit-agnostic: the receiver counts
/// chunks (it doesn't know the size up front), and the ratio is all the UI needs.
struct TransferProgress: Equatable {
    let name: String
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
}

/// Progress of a whole outgoing batch (one or many files), shown as a single bar.
///
/// The bar is the **batch's** byte progress so it only ever moves forward, while the label names
/// the file in flight with that file's own percentage: `rapor.pdf (50%)`.
struct BatchProgress: Equatable {
    var currentName: String
    var currentDone: Int
    var currentTotal: Int
    /// 1-based position of the file in flight.
    var index: Int
    var count: Int
    var doneBytes: Int
    var totalBytes: Int

    var currentFraction: Double { currentTotal > 0 ? min(1, Double(currentDone) / Double(currentTotal)) : 0 }
    var currentPercent: Int { Int((currentFraction * 100).rounded()) }
    var overallFraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    var label: String { "\(currentName) (\(currentPercent)%)" }

    /// The name before anything has been sent, so the zone has something to show immediately.
    static func starting(name: String, count: Int = 1) -> BatchProgress {
        BatchProgress(currentName: name, currentDone: 0, currentTotal: 0, index: 1, count: count,
                      doneBytes: 0, totalBytes: 0)
    }
}

/// Counts files that arrive in one burst, so a multi-file send raises one updating banner instead
/// of one per file. A gap longer than `gap` ends the burst and the next file starts a new count.
struct BurstCounter {
    let gap: TimeInterval
    private var count = 0
    private var last = Date.distantPast

    init(gap: TimeInterval = 30) { self.gap = gap }

    /// Record one arrival at `now`; returns its position in the current burst (1 for the first).
    mutating func note(at now: Date = Date()) -> Int {
        if now.timeIntervalSince(last) > gap { count = 0 }
        last = now
        count += 1
        return count
    }
}

/// A file queued for the phone. `dir` is the folder it sits in relative to the dropped root
/// (`Photos/2024`), nil for a file dropped on its own.
struct OutgoingItem: Equatable, Sendable {
    let url: URL
    let name: String
    let dir: String?
    let size: Int
}

/// Turns what the user dropped (files and/or folders) into a flat, ordered list of files.
enum FileBatchPlanner {
    /// A dropped folder is walked, and a runaway one (a home directory, `node_modules`) must not
    /// queue forever.
    static let maxFiles = 1000

    struct Plan {
        var items: [OutgoingItem] = []
        /// Human-readable reasons something was left out, for the summary notification.
        var problems: [String] = []
    }

    static func plan(urls: [URL], fileManager fm: FileManager = .default) -> Plan {
        var plan = Plan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

        for dropped in urls {
            // A symlink the user dropped on purpose is followed; ones found *inside* a folder
            // are skipped below (they can loop, or point outside the tree they were dropped in).
            let url = dropped.resolvingSymlinksInPath()
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                plan.problems.append("Couldn't read \(name)")
                continue
            }

            if values.isDirectory == true {
                walk(folder: url, rootName: name, fm: fm, keys: keys, into: &plan)
            } else {
                add(file: url, name: name, dir: nil, size: values.fileSize, into: &plan)
            }
            if plan.items.count >= maxFiles { break }
        }
        return plan
    }

    private static func walk(folder: URL, rootName: String, fm: FileManager,
                             keys: [URLResourceKey], into plan: inout Plan) {
        let root = folder.standardizedFileURL
        let rootComponents = root.pathComponents
        var found = 0
        var unreadable = 0

        // No `.skipsPackageDescendants`: a package (.app, .pages) is a folder the user expects to
        // arrive whole, so it is sent as a tree like any other.
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in unreadable += 1; return true }
        ) else {
            plan.problems.append("Couldn't read \(rootName)")
            return
        }

        for case let entry as URL in walker {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                unreadable += 1
                continue
            }
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isDirectory == true { continue }

            if plan.items.count >= maxFiles {
                plan.problems.append("\(rootName): only the first \(maxFiles) files were queued")
                return
            }
            // Components below the dropped root, minus the file itself.
            let parts = Array(entry.standardizedFileURL.pathComponents.dropFirst(rootComponents.count).dropLast())
            let dir = ([rootName] + parts).joined(separator: "/")
            let before = plan.items.count
            add(file: entry, name: entry.lastPathComponent, dir: dir, size: values.fileSize, into: &plan)
            if plan.items.count > before { found += 1 }
        }

        if unreadable > 0 { plan.problems.append("\(rootName): \(unreadable) item(s) couldn't be read") }
        if found == 0 && unreadable == 0 && !plan.problems.contains(where: { $0.hasPrefix("\(rootName):") }) {
            plan.problems.append("\(rootName) has no files to send")
        }
    }

    private static func add(file: URL, name: String, dir: String?, size: Int?, into plan: inout Plan) {
        guard let size, size > 0 else {
            plan.problems.append("\(name) is empty")
            return
        }
        guard size <= FileFrame.maxTransferBytes else {
            plan.problems.append("\(name) is larger than \(FileFrame.maxTransferBytes / (1024 * 1024)) MB")
            return
        }
        plan.items.append(OutgoingItem(url: file, name: name, dir: dir, size: size))
    }
}

/// The sender's flow-control window: at most `capacity` chunks unacknowledged at once.
///
/// **Replaces a `DispatchSemaphore`**, and that is the point. libdispatch kills the process when a
/// semaphore is deallocated while its value is below its initial value, and a transfer that ended
/// early (a timeout, a read error, a dropped link) leaves exactly that behind — the *next* send
/// replaced it and crashed the app. A counter behind an `NSCondition` has no such trap, and it can
/// also be *failed*: a nack or a lost connection wakes the waiting sender at once instead of
/// leaving it to sit out the full ack timeout.
///
/// Acks are tracked per chunk, so a duplicate or stray ack is harmless.
final class AckWindow: @unchecked Sendable {
    enum Wait: Equatable {
        case ok
        case timeout
        case failed(String)
    }

    private let cond = NSCondition()
    private let capacity: Int
    private var pending = Set<Int>()
    private var failure: String?

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Block until there is room for chunk `seq`, then claim a slot for it.
    func reserve(_ seq: Int, timeout: TimeInterval) -> Wait {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let failure { return .failed(failure) }
            if pending.count < capacity {
                pending.insert(seq)
                return .ok
            }
            if !cond.wait(until: deadline) {
                if let failure { return .failed(failure) }
                if pending.count < capacity { pending.insert(seq); return .ok }
                return .timeout
            }
        }
    }

    /// The receiver stored chunk `seq`.
    func acknowledge(_ seq: Int) {
        cond.lock()
        pending.remove(seq)
        cond.broadcast()
        cond.unlock()
    }

    /// Give up on the transfer: wakes every waiter with `reason`. The first reason wins.
    func fail(_ reason: String) {
        cond.lock()
        if failure == nil { failure = reason }
        cond.broadcast()
        cond.unlock()
    }

    /// Wait for every outstanding chunk to be acknowledged — only then has the file really been
    /// stored, which is what makes "sent" a delivery receipt rather than an optimistic guess.
    func drain(timeout: TimeInterval) -> Wait {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let failure { return .failed(failure) }
            if pending.isEmpty { return .ok }
            if !cond.wait(until: deadline) {
                if let failure { return .failed(failure) }
                return pending.isEmpty ? .ok : .timeout
            }
        }
    }
}

/// What a finished (or cancelled) batch amounted to, for the one summary notification.
struct BatchResult: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let name: String
        let reason: String
    }

    var sent: [String] = []
    var failures: [Failure] = []
    /// Files never attempted because the batch was cancelled or the link died.
    var notSent = 0
    var cancelled = false
}

/// Streams local files to the phone in `FileFrame.chunkRawBytes` chunks — the Mac→phone mirror of
/// the phone's `ClipForegroundService.sendAsFile`.
///
/// **NOT `@MainActor`** (the same shape `LanServer` uses): the send loop blocks on an ack window,
/// which must never happen on the main actor, so all of it runs on a private serial queue and the
/// callbacks marshal back out. `ack`/`nack` are lock-guarded rather than queue-hopping — the queue
/// is *blocked* waiting on the window when an ack arrives, so dispatching onto it would deadlock.
///
/// One batch runs at a time and files in it go strictly one after another; a drop that arrives
/// mid-batch is appended to it, so the user sees one bar and gets one summary however many drags
/// it took. Two relay limits shape the pacing, and tripping either drops the connection rather
/// than the frame: the 8 MiB per-peer send buffer (hence the small ack window) and the
/// 120-frames-per-10 s rate limit (hence `relayChunkInterval`). A LAN-direct transfer goes
/// straight to the phone and has neither, so it isn't paced.
final class FileSender: @unchecked Sendable {
    enum Route: Sendable {
        case lan
        case relay
    }

    struct Config: Sendable {
        var ackWindow = 4
        var ackTimeout: TimeInterval = 30
        var relayChunkInterval: TimeInterval = 0.125
        var chunkBytes = FileFrame.chunkRawBytes

        init() {}
    }

    /// Sends one assembled `file` plaintext on whichever link is up *right now* and reports which
    /// one, or nil when there is none. Called per chunk, so a LAN link that drops mid-file falls
    /// over to the relay (or ends the transfer at once) instead of shouting into the void.
    typealias Transport = @Sendable (Data) -> Route?

    private final class Transfer: @unchecked Sendable {
        let id: String
        let window: AckWindow
        init(id: String, window: AckWindow) { self.id = id; self.window = window }
    }

    private final class Batch: @unchecked Sendable {
        var items: [OutgoingItem]
        var next = 0
        var cancelled = false
        var transfer: Transfer?
        var totalBytes: Int
        var doneBytes = 0
        /// When the last relay chunk left, across files: the relay's rate limit is per connection.
        var lastRelayAt = Date.distantPast
        let transport: Transport
        let progress: @Sendable (BatchProgress) -> Void
        let done: @Sendable (BatchResult) -> Void

        init(items: [OutgoingItem], transport: @escaping Transport,
             progress: @escaping @Sendable (BatchProgress) -> Void,
             done: @escaping @Sendable (BatchResult) -> Void) {
            self.items = items
            self.totalBytes = items.reduce(0) { $0 + $1.size }
            self.transport = transport
            self.progress = progress
            self.done = done
        }
    }

    private enum ItemOutcome {
        case sent
        /// `fatal`: the link or the phone is gone, so trying the rest would only repeat the wait.
        case failed(String, fatal: Bool)
    }

    private let config: Config
    private let queue = DispatchQueue(label: "dev.grkn.LinkToMac.filesend")
    private let lock = NSLock()
    private var active: Batch?

    init(config: Config = Config()) { self.config = config }

    /// True while a batch is running.
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

    /// Queue `items` for the phone. If a batch is already running they join it (and the bar's
    /// total grows); otherwise a new batch starts. Closures are those of the batch's first call.
    func send(
        items: [OutgoingItem],
        transport: @escaping Transport,
        progress: @escaping @Sendable (BatchProgress) -> Void,
        done: @escaping @Sendable (BatchResult) -> Void
    ) {
        guard !items.isEmpty else { return }
        lock.lock()
        if let batch = active {
            batch.items += items
            batch.totalBytes += items.reduce(0) { $0 + $1.size }
            lock.unlock()
            return
        }
        let batch = Batch(items: items, transport: transport, progress: progress, done: done)
        active = batch
        lock.unlock()
        queue.async { [self] in run(batch) }
    }

    /// Stop after the chunk in flight; files not yet started are dropped.
    func cancel() {
        lock.lock()
        let batch = active
        batch?.cancelled = true
        let window = batch?.transfer?.window
        lock.unlock()
        window?.fail("Cancelled")
    }

    /// The phone stored chunk `seq` of `id`. Safe from any thread.
    func ack(id: String, seq: Int) {
        lock.lock()
        let window = active?.transfer?.id == id ? active?.transfer?.window : nil
        lock.unlock()
        window?.acknowledge(seq)
    }

    /// The phone could not store `id` — fail it now rather than after the ack timeout.
    func nack(id: String, reason: String?) {
        lock.lock()
        let window = active?.transfer?.id == id ? active?.transfer?.window : nil
        lock.unlock()
        window?.fail(reason ?? "Your phone couldn't save it")
    }

    /// The link went away under the file in flight (a socket write failed).
    func failActive(_ reason: String) {
        lock.lock()
        let window = active?.transfer?.window
        lock.unlock()
        window?.fail(reason)
    }

    // MARK: - Run loop

    private func run(_ batch: Batch) {
        var result = BatchResult()
        var stopped = false

        while true {
            lock.lock()
            if batch.cancelled || stopped || batch.next >= batch.items.count {
                result.cancelled = batch.cancelled
                result.notSent = (batch.cancelled || stopped) ? batch.items.count - batch.next : 0
                // Cleared under the same lock `send` appends under, so a drop racing the end of
                // the batch either lands in it or starts a fresh one — never falls between.
                active = nil
                lock.unlock()
                break
            }
            let item = batch.items[batch.next]
            batch.next += 1
            let index = batch.next
            lock.unlock()

            let outcome = sendOne(item, index: index, batch: batch)

            lock.lock()
            batch.doneBytes += item.size
            batch.transfer = nil
            let cancelled = batch.cancelled
            lock.unlock()

            switch outcome {
            case .sent:
                result.sent.append(item.name)
            case let .failed(reason, fatal):
                if !cancelled { result.failures.append(.init(name: item.name, reason: reason)) }
                if fatal { stopped = true }
            }
        }
        batch.done(result)
    }

    private func sendOne(_ item: OutgoingItem, index: Int, batch: Batch) -> ItemOutcome {
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            return .failed("Couldn't open \(item.name)", fatal: false)
        }
        defer { try? handle.close() }

        let chunk = config.chunkBytes
        let count = (item.size + chunk - 1) / chunk
        let id = String(UUID().uuidString.prefix(8))
        let window = AckWindow(capacity: config.ackWindow)
        let mime = Self.mimeType(for: item.url)

        lock.lock()
        batch.transfer = Transfer(id: id, window: window)
        let cancelledEarly = batch.cancelled
        lock.unlock()
        if cancelledEarly { return .failed("Cancelled", fatal: false) }

        report(batch, item, index: index, sent: 0)

        var sent = 0
        for seq in 0..<count {
            switch window.reserve(seq, timeout: config.ackTimeout) {
            case .ok: break
            case .timeout: return .failed("Your phone stopped responding", fatal: true)
            case let .failed(reason): return .failed(reason, fatal: reason != "Cancelled" && Self.isLinkFailure(reason))
            }
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else {
                return .failed("\(item.name) changed while sending", fatal: false)
            }
            // Pace by where the *previous* chunk went: the relay's rate limit is per connection,
            // and a LAN chunk costs it nothing.
            let wait = config.relayChunkInterval - Date().timeIntervalSince(batch.lastRelayAt)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }

            let payload = FileFrame.payload(
                mime: mime, bytes: data, name: item.name, dir: item.dir,
                disp: FileFrame.dispSave, id: id, seq: seq, count: count
            )
            guard let route = batch.transport(payload) else {
                return .failed("Lost the connection to your phone", fatal: true)
            }
            if route == .relay { batch.lastRelayAt = Date() }
            sent += data.count
            report(batch, item, index: index, sent: sent)
        }

        switch window.drain(timeout: config.ackTimeout) {
        case .ok: return .sent
        case .timeout: return .failed("Your phone stopped responding", fatal: true)
        case let .failed(reason): return .failed(reason, fatal: reason != "Cancelled" && Self.isLinkFailure(reason))
        }
    }

    /// A nack names a problem with one file (the phone is fine and the next file may work); a
    /// dead link is a problem with all of them.
    private static func isLinkFailure(_ reason: String) -> Bool {
        reason.hasPrefix("Lost the connection") || reason.hasPrefix("Your phone stopped")
    }

    private func report(_ batch: Batch, _ item: OutgoingItem, index: Int, sent: Int) {
        lock.lock()
        let progress = BatchProgress(
            currentName: item.name, currentDone: sent, currentTotal: item.size,
            index: index, count: batch.items.count,
            doneBytes: batch.doneBytes + sent, totalBytes: batch.totalBytes
        )
        lock.unlock()
        batch.progress(progress)
    }

    /// Best-effort content type from the path extension; the phone only uses it to label the file
    /// and to pick a viewer, so an unknown type falling back to octet-stream is harmless.
    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
