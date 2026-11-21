import Foundation
import Testing

/// `stat.lan`, the Mac's LAN address hint: runs `protocol-vectors/stat-lan.json`. The phone's `StatLanVectorTest` runs the same `parse`
/// cases; the `pick` cases (what the Mac writes from its interface list) are the Mac's alone.
@Suite struct StatLanVectorTests {
    private func cases(_ section: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/stat-lan.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return ((doc?[section] as? [String: Any])?["cases"] as? [[String: Any]]) ?? []
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    @Test func theVectorFileHasTheCasesThisSuiteRuns() throws {
        #expect(try cases("parse").count >= 40)
        #expect(try cases("pick").count >= 10)
    }

    @Test func parseVectors() throws {
        for c in try cases("parse") {
            let stat = c["stat"] as? [String: Any] ?? [:]
            let expect = c["expect"] as? [String: Any] ?? [:]
            let update = StatLan.parse(stat: stat)
            switch expect["update"] as? String {
            case "absent":
                #expect(update == .absent, "\(name(c))")
            case "hints":
                let want = (expect["hints"] as? [String]) ?? []
                if case .hints(let got) = update {
                    #expect(got.map { "\($0.host):\($0.port)" } == want, "\(name(c))")
                } else {
                    Issue.record("\(name(c)): expected hints, got absent")
                }
            default:
                Issue.record("\(name(c)): unknown expected update")
            }
        }
    }

    @Test func pickVectors() throws {
        for c in try cases("pick") {
            let raw = c["interfaces"] as? [[String: Any]] ?? []
            let interfaces = raw.map {
                NetInterface(
                    name: $0["name"] as? String ?? "",
                    up: $0["up"] as? Bool ?? false,
                    running: $0["running"] as? Bool ?? false,
                    loopback: $0["loopback"] as? Bool ?? false,
                    ipv4: $0["ipv4"] as? String)
            }
            let port = c["port"] as? Int ?? 0
            let want = (c["expect"] as? [String]) ?? []
            #expect(LanAddressHint.pick(interfaces: interfaces, port: port) == want, "\(name(c))")
        }
    }

    /// What the Mac writes must be readable by the phone's rules: every picked address survives `parse`.
    @Test func everythingPickedParsesBack() throws {
        for c in try cases("pick") {
            let raw = c["interfaces"] as? [[String: Any]] ?? []
            let interfaces = raw.map {
                NetInterface(name: $0["name"] as? String ?? "", up: $0["up"] as? Bool ?? false, running: $0["running"] as? Bool ?? false,
                             loopback: $0["loopback"] as? Bool ?? false, ipv4: $0["ipv4"] as? String)
            }
            let picked = LanAddressHint.pick(interfaces: interfaces, port: c["port"] as? Int ?? 0)
            guard case .hints(let back) = StatLan.parse(stat: ["lan": picked]) else {
                #expect(picked.isEmpty, "\(name(c))"); continue
            }
            #expect(back.map { "\($0.host):\($0.port)" } == picked, "\(name(c))")
        }
    }

    @Test func theStatFragmentIsAJsonArrayOrNothing() throws {
        #expect(LanAddressHint.statFragment([]) == nil)
        #expect(LanAddressHint.statFragment(["192.168.1.10:53124"]) == "\"lan\":[\"192.168.1.10:53124\"]")
        #expect(LanAddressHint.statFragment(["192.168.1.10:53124", "10.0.0.7:53124"]) == "\"lan\":[\"192.168.1.10:53124\",\"10.0.0.7:53124\"]")
        // the whole payload stays valid JSON and the phone's parser reads it back
        let json = "{" + (LanAddressHint.statFragment(["192.168.1.10:53124"]) ?? "") + "}"
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        #expect(StatLan.parse(stat: obj) == .hints([StatLan.Hint(host: "192.168.1.10", port: 53124)]))
    }

    @Test func theFragmentRefusesWhatThePhoneWouldRefuse() {
        // a malformed address must never reach the wire, even if a caller passes one
        #expect(LanAddressHint.statFragment(["8.8.8.8:53124"]) == nil)
        #expect(LanAddressHint.statFragment(["not an address", "192.168.1.10:53124"]) == "\"lan\":[\"192.168.1.10:53124\"]")
    }

    @Test func theLiveInterfaceListIsUsableAndNeverLoopback() {
        // The real machine: whatever it has, the result must obey the same rules (this also proves getifaddrs wiring does not crash).
        let live = LanAddressHint.currentInterfaces()
        for i in live where i.loopback { #expect(LanAddressHint.pick(interfaces: [i], port: 53124).isEmpty) }
        for hint in LanAddressHint.pick(interfaces: live, port: 53124) {
            #expect(StatLan.parseItem(hint) != nil, "picked \(hint.count) chars that the phone would refuse")
        }
    }
}
