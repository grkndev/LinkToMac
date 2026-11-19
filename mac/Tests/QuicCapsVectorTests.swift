import Foundation
import Testing

/// `stat.caps` (plan stage 1.4): how each side learns whether the other speaks the QUIC session protocol. Runs the shared vectors
/// (`protocol-vectors/quic-control.json`, section `stat`) — the phone's `QuicCapsVectorTest` runs the same file — plus what only the Mac
/// decides: a phone that is on BOTH links stays known until it has left both.
@Suite struct QuicCapsVectorTests {
    private func cases(_ kind: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/quic-control.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let stat = doc?["stat"] as? [String: Any]
        let all = (stat?["cases"] as? [[String: Any]]) ?? []
        return all.filter { $0["kind"] as? String == kind }
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }
    private func set(_ any: Any?) -> Set<String> { Set((any as? [String]) ?? []) }

    @Test func theVectorFileHasTheCasesThisSuiteRuns() throws {
        #expect(try !cases("parse").isEmpty)
        #expect(try !cases("sequence").isEmpty)
        #expect(try !cases("available").isEmpty)
        #expect(try !cases("advertise").isEmpty)
    }

    @Test func parseVectors() throws {
        for c in try cases("parse") {
            let stat = c["stat"] as? [String: Any] ?? [:]
            let expect = c["expect"] as? [String: Any] ?? [:]
            let update = QuicCaps.parse(stat: stat)
            switch expect["update"] as? String {
            case "absent": #expect(update == .absent, "\(name(c))")
            case "set": #expect(update == .set(set(expect["caps"])), "\(name(c))")
            default: Issue.record("\(name(c)): unknown expected update")
            }
        }
    }

    @Test func sequenceVectors() throws {
        for c in try cases("sequence") {
            var peer = PeerCaps()
            let steps = c["steps"] as? [[String: Any]] ?? []
            let after = c["after"] as? [[String]] ?? []
            #expect(steps.count == after.count, "\(name(c)): steps and after differ in length")
            for (i, step) in steps.enumerated() {
                switch step["op"] as? String {
                case "stat": peer.applyStat(step["stat"] as? [String: Any] ?? [:])
                case "offline": peer.peerWentOffline()
                default: Issue.record("\(name(c)) step \(i): unknown op")
                }
                #expect(peer.caps == Set(after[i]), "\(name(c)) after step \(i)")
            }
        }
    }

    @Test func availableVectors() throws {
        for c in try cases("available") {
            let got = QuicCaps.available(onLan: c["onLan"] as? Bool ?? false, caps: set(c["caps"]))
            #expect(got == (c["expect"] as? Bool), "\(name(c))")
            var peer = PeerCaps(caps: set(c["caps"]))
            #expect(peer.quicAvailable(onLan: c["onLan"] as? Bool ?? false) == got, "\(name(c)) via PeerCaps")
            peer.peerWentOffline()
            #expect(!peer.quicAvailable(onLan: true), "\(name(c)) after offline")
        }
    }

    @Test func advertiseVectors() throws {
        for c in try cases("advertise") {
            #expect(QuicCaps.advertised(supportsQuic: c["supportsQuic"] as? Bool ?? false) == (c["expect"] as? [String]), "\(name(c))")
        }
    }

    // MARK: only the Mac decides

    @Test func theStatFragmentIsOmittedUnlessQuicIsSupportedSoTheFrameStaysAsItWas() {
        #expect(QuicCaps.statFragment(supportsQuic: false) == nil)
        #expect(QuicCaps.statFragment(supportsQuic: true) == #""caps":["q1"]"#)
    }

    @Test func theFragmentFitsInsideAStatObjectThePhoneParses() throws {
        let json = "{" + #""name":"Mac",\#(QuicCaps.statFragment(supportsQuic: true)!)"# + "}"
        let raw = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(QuicCaps.parse(stat: raw) == .set(["q1"]))
    }

    @Test func aPhoneOnBothLinksStaysKnownUntilItHasLeftBoth() {
        var peer = PeerCaps(caps: ["q1"])
        peer.linksChanged(relayOnline: false, lanConnected: true)    // relay dropped, LAN still there: same phone
        #expect(peer.caps == ["q1"])
        peer.linksChanged(relayOnline: true, lanConnected: false)    // LAN dropped, relay still there
        #expect(peer.caps == ["q1"])
        peer.linksChanged(relayOnline: true, lanConnected: true)
        #expect(peer.caps == ["q1"])
        peer.linksChanged(relayOnline: false, lanConnected: false)   // gone from both
        #expect(peer.caps.isEmpty)
    }

    @Test func aFreshPeerCapsKnowsNothing() {
        #expect(PeerCaps().caps.isEmpty)
        #expect(!PeerCaps().quicAvailable(onLan: true))
    }
}
