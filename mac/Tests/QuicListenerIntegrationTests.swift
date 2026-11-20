import Darwin
import Foundation
import Testing

/// The real server (Network.framework QUIC listener + the session rules) against the Rust client of the phone side
/// (`mobile/native-src/quic-core/examples/echo_client.rs`), over localhost. Build the client first (`mac/scripts/quic-it.sh` does):
/// without `target/debug/examples/echo_client` these tests are skipped, so a Mac-only checkout still runs the unit tests.
///
/// The Mac side is driven exactly as the app drives it (`QuicServer.receive` with a phone's `q.req`, the offer read back from the
/// actions it sends), only the relay/LAN transport in between is missing. The `echo` kind exists in Debug builds only, which is what
/// `xcodebuild test` builds.

private let echoClientURL: URL? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repo root
    let url = root.appendingPathComponent("mobile/native-src/quic-core/target/debug/examples/echo_client")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

/// The production phone client (`quic_core::client::Client`) driven from the command line (`examples/session_client.rs`).
private let sessionClientURL: URL? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repo root
    let url = root.appendingPathComponent("mobile/native-src/quic-core/target/debug/examples/session_client")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

private final class ActionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QuicAction] = []
    func add(_ action: QuicAction) { lock.lock(); items.append(action); lock.unlock() }
    var all: [QuicAction] { lock.lock(); defer { lock.unlock() }; return items }
}

private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

/// One server with a throwaway Keychain identity, and the client binary.
private final class Harness: @unchecked Sendable {
    let label = "dev.grkn.LinkToMac.test/quic-it-\(UUID().uuidString)"
    let name = "LinkToMacIT-\(UUID().uuidString)"
    let sid = UUID().uuidString.lowercased()
    let identity: QuicIdentity
    let actions = ActionBox()
    let server: QuicServer

    init(options: QuicListener.Options = QuicListener.Options(preferredPort: 0),
         config: QuicSession.Config = QuicSession.Config()) throws {
        identity = try QuicIdentity.loadOrCreate(label: label, commonName: name)
        var config = config
        config.supportedKinds = [.echo]
        let box = actions
        server = QuicServer(identity: identity, config: config, options: options, send: { box.add($0) })
    }

    func close() {
        server.end()
        Thread.sleep(forTimeInterval: 0.2)
        QuicIdentity.reset(label: label, commonName: name)
    }

    /// A phone's `q.req` for the echo kind; returns the Mac's offer.
    func request() -> QuicOffer? {
        server.receive(.request(sid: sid, kind: .echo), onLan: true)
        var offer: QuicOffer?
        _ = waitFor(5) {
            for case let .offer(o) in actions.all { offer = o }
            return offer != nil
        }
        return offer
    }

    func state() -> QuicSession.State {
        let done = DispatchSemaphore(value: 0)
        let box = StateBox()
        server.state { box.value = $0; done.signal() }
        _ = done.wait(timeout: .now() + 2)
        return box.value
    }

    func waitForState(_ seconds: Double, _ wanted: QuicSession.State) -> Bool { waitFor(seconds) { state() == wanted } }

    func client(_ scenario: String, _ offer: QuicOffer, extra: [String] = [], production: Bool = false) -> Process {
        let process = Process()
        process.executableURL = production ? sessionClientURL : echoClientURL
        process.arguments = ["--addr", "127.0.0.1:\(offer.port)", "--fp", offer.fp, "--tok", offer.tok, "--scenario", scenario] + extra
        return process
    }

    /// Runs the client to completion: its exit status and its RESULT line.
    func run(_ scenario: String, _ offer: QuicOffer, extra: [String] = [], limit: Double = 60, production: Bool = false) -> (passed: Bool, line: String) {
        let process = client(scenario, offer, extra: extra, production: production)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, "could not start the client: \(error)") }
        let finished = waitFor(limit) { !process.isRunning }
        if !finished { process.terminate() }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").last(where: { $0.hasPrefix("RESULT") }).map(String.init) ?? text
        return (finished && process.terminationStatus == 0 && line.contains(" PASS "), line)
    }

    /// True while THIS process still has a UDP socket on `port`.
    func listening(on port: Int) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iUDP:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        lsof.waitUntilExit()
        return !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
    }
}

private final class StateBox: @unchecked Sendable { var value: QuicSession.State = .idle }

@Suite(.serialized, .enabled(if: echoClientURL != nil, "build the Rust client first: mac/scripts/quic-it.sh"), .timeLimit(.minutes(3)))
struct QuicListenerIntegrationTests {
    @Test func theRightFingerprintAndTokenOpenASessionThatEchoes() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        #expect(offer.port > 0)
        #expect(offer.fp == h.identity.fingerprint)
        let result = h.run("happy", offer)
        #expect(result.passed, "\(result.line)")
        // The client closed the connection itself: the Mac notices and ends the session.
        #expect(h.waitForState(5, .ended(.connectionLost)), "state \(h.state())")
        #expect(!h.listening(on: offer.port))
    }

    @Test func aDatagramThatArrivesBeforeTheTokenIsDropped() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("early-datagram", offer)
        #expect(result.passed, "\(result.line)")
    }

    @Test func aWrongTokenIsRefusedInBandAndTheOfferStaysValid() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let refused = h.run("wrong-tok", offer)
        #expect(refused.passed, "\(refused.line)")
        #expect(h.state() == .offered)
        let accepted = h.run("happy", offer)
        #expect(accepted.passed, "\(accepted.line)")
    }

    @Test func aWrongFingerprintNeverGetsPastTheHandshakeAndTheListenerKeepsServing() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let refused = h.run("wrong-fp", offer)
        #expect(refused.passed, "\(refused.line)")
        let accepted = h.run("happy", offer)
        #expect(accepted.passed, "\(accepted.line)")
    }

    @Test func manyMoreStreamsThanTheInitialLimitNeverBlock() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("streams", offer, extra: ["--count", "5000"], limit: 120)
        #expect(result.passed, "\(result.line)")
    }

    @Test func withoutRaisingTheCreditTheSenderStallsAtTheInitialLimit() throws {
        var options = QuicListener.Options(preferredPort: 0)
        options.raiseStreamCredit = false
        let h = try Harness(options: options)
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("streams", offer, extra: ["--count", "3000", "--expect-block"], limit: 60)
        #expect(result.passed, "\(result.line)")
        let at = result.line.components(separatedBy: "stalled at stream ").last?.split(separator: " ").first.flatMap { Int($0) }
        #expect((900 ... 1100).contains(at ?? -1), "\(result.line)")
    }

    @Test func aHugeInitialLimitIsClippedAt4096() throws {
        // Stage 0.5 finding 14: asking for a limit that is practically unlimited does not help, the connection stalls at 4096.
        var options = QuicListener.Options(preferredPort: 0)
        options.raiseStreamCredit = false
        options.initialMaxStreamsUnidirectional = 1 << 40
        let h = try Harness(options: options)
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("streams", offer, extra: ["--count", "6000", "--expect-block"], limit: 90)
        #expect(result.passed, "\(result.line)")
        let at = result.line.components(separatedBy: "stalled at stream ").last?.split(separator: " ").first.flatMap { Int($0) }
        #expect((4000 ... 4200).contains(at ?? -1), "\(result.line)")
    }

    @Test func aTakenPreferredPortIsReplacedByAFreeOneThatTheOfferReports() throws {
        // Hold a UDP port on both address families so the listener cannot share it.
        func hold(family: Int32, port: UInt16) -> Int32? {
            let fd = socket(family, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            var ok = false
            if family == AF_INET {
                var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
                ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            } else {
                var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
                ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
            }
            if !ok { close(fd); return nil }
            return fd
        }
        // A free port: bind to 0 and read it back.
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        var any = sockaddr_in(); any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); any.sin_family = sa_family_t(AF_INET)
        _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
        let taken = UInt16(bigEndian: bound.sin_port)
        close(probe)
        let v4 = try #require(hold(family: AF_INET, port: taken))
        let v6 = hold(family: AF_INET6, port: taken)
        defer { close(v4); if let v6 { close(v6) } }

        let h = try Harness(options: QuicListener.Options(preferredPort: taken))
        defer { h.close() }
        let offer = try #require(h.request())
        #expect(offer.port != Int(taken), "the offer still names the taken port")
        let result = h.run("happy", offer)
        #expect(result.passed, "\(result.line)")
    }

    @Test func aSecondConnectionWithTheSameTokenAndASecondRequestAreRefused() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        // Another request while this session is open: busy, the session is untouched. (Asked first: once the client below has
        // finished and closed, the session is over and a new request would rightly be served.)
        let otherSid = UUID().uuidString.lowercased()
        h.server.receive(.request(sid: otherSid, kind: .echo), onLan: true)
        #expect(waitFor(3) { h.actions.all.contains(.reject(sid: otherSid, reason: .busy)) })
        #expect(h.state() == .offered)
        let second = h.run("second-conn", offer)
        #expect(second.passed, "\(second.line)")
    }

    @Test func endingTheSessionTellsThePhoneInBandAndFreesThePort() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let process = h.client("hold", offer, extra: ["--wait", "20"])
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        #expect(h.waitForState(10, .connected), "state \(h.state())")
        h.server.end()
        #expect(waitFor(10) { !process.isRunning })
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && line.contains(" PASS "), "\(line)")
        #expect(h.actions.all.contains(.end(sid: h.sid)))
        #expect(waitFor(5) { !h.listening(on: offer.port) })
    }

    @Test func thePhoneEndingFreesTheMacsSideEvenIfItStaysConnected() throws {
        // Network.framework cannot make the peer see a close, and a phone that sent `q.end` may well keep its connection a moment longer:
        // the Mac must release its own side regardless (the plan: "the Mac frees its local resources on its own").
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let process = h.client("linger", offer, extra: ["--wait", "8"])
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        #expect(h.waitForState(10, .connected), "state \(h.state())")
        h.server.receive(.end(sid: h.sid), onLan: true)
        #expect(h.waitForState(3, .ended(.peerEnded)))
        #expect(waitFor(4) { !h.listening(on: offer.port) }, "the Mac still holds the UDP port")
        #expect(process.isRunning, "the client was meant to still be connected while the Mac released its side")
    }

    @Test func anOfferNobodyUsesExpiresAndFreesThePort() throws {
        var config = QuicSession.Config()
        config.offerValidMs = 1500
        let h = try Harness(config: config)
        defer { h.close() }
        let offer = try #require(h.request())
        #expect(h.waitForState(5, .ended(.offerTimeout)), "state \(h.state())")
        #expect(h.actions.all.contains(.end(sid: h.sid)))
        #expect(waitFor(5) { !h.listening(on: offer.port) })
    }

    @Test func trafficKeepsASessionAliveAndSilenceEndsIt() throws {
        var config = QuicSession.Config()
        config.idleMs = 3000
        let h = try Harness(config: config)
        defer { h.close() }
        let offer = try #require(h.request())
        // Six echoed lines over six seconds (twice the idle limit), then silence.
        let result = h.run("chatter", offer, limit: 40)
        #expect(result.passed, "\(result.line)")
        #expect(h.state() == .ended(.idleTimeout))
    }

    @Test func aSessionIdleForThirtySecondsEndsAndFreesThePort() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("idle", offer, limit: 60)
        #expect(result.passed, "\(result.line)")
        #expect(h.state() == .ended(.idleTimeout))
        #expect(waitFor(5) { !h.listening(on: offer.port) })
    }
}


/// The same server against the client that actually ships (the library the phone's JNI layer wraps), not the protocol probe above.
@Suite(.serialized, .enabled(if: sessionClientURL != nil, "build the Rust examples first: mac/scripts/quic-it.sh"), .timeLimit(.minutes(3)))
struct QuicProductionClientIntegrationTests {
    @Test func theShippingClientOpensASessionAndEchoes() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("happy", offer, production: true)
        #expect(result.passed, "\(result.line)")
        #expect(h.waitForState(5, .ended(.connectionLost)), "state \(h.state())")
    }

    @Test func theShippingClientReportsAWrongFingerprintAsSuch() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("wrong-fp", offer, production: true)
        #expect(result.passed, "\(result.line)")
        #expect(h.run("happy", offer, production: true).passed, "the listener must keep serving after a refused handshake")
    }

    @Test func theShippingClientReportsAWrongTokenAsRefusedAndTheOfferStaysValid() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("wrong-tok", offer, production: true)
        #expect(result.passed, "\(result.line)")
        #expect(h.state() == .offered)
        let accepted = h.run("happy", offer, production: true)
        #expect(accepted.passed, "\(accepted.line)")
    }

    @Test func theShippingClientOpensMoreStreamsThanTheInitialLimit() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let result = h.run("streams", offer, extra: ["--count", "2500"], limit: 120, production: true)
        #expect(result.passed, "\(result.line)")
    }

    @Test func theLinkGoingAwayEndsTheSessionTellsThePhoneAndFreesThePort() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let process = h.client("end", offer, extra: ["--wait", "20"], production: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        #expect(h.waitForState(10, .connected), "state \(h.state())")
        h.server.linkLost()
        #expect(h.waitForState(3, .ended(.linkLost)), "state \(h.state())")
        #expect(waitFor(10) { !process.isRunning })
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && line.contains(" PASS "), "\(line)")   // the phone got END
        #expect(h.actions.all.contains(.end(sid: h.sid)))
        #expect(waitFor(5) { !h.listening(on: offer.port) })
    }

    @Test func theShippingClientLearnsThatTheMacEndedTheSession() throws {
        let h = try Harness()
        defer { h.close() }
        let offer = try #require(h.request())
        let process = h.client("end", offer, extra: ["--wait", "20"], production: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        #expect(h.waitForState(10, .connected), "state \(h.state())")
        h.server.end()
        #expect(waitFor(10) { !process.isRunning })
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && line.contains(" PASS "), "\(line)")
    }
}
