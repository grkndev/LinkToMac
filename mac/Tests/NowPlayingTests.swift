import Foundation
import Testing

/// Runs the shared vectors (`protocol-vectors/stat-media.json`) — the phone's `MediaStateTest` runs the
/// same file, so a field renamed on one side turns a test red instead of blanking the card.
@Suite struct NowPlayingTests {
    private func cases(kinds: Set<String>) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/stat-media.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let all = (doc?["cases"] as? [[String: Any]]) ?? []
        return all.filter { kinds.contains($0["kind"] as? String ?? "") }
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    /// Compares what `parse` produced with the vector's `expect`, key by key.
    private func check(_ update: NowPlaying.Update, against expect: [String: Any], _ label: String) {
        switch expect["update"] as? String {
        case "absent": #expect(update == .absent, "\(label)")
        case "cleared": #expect(update == .cleared, "\(label)")
        case "unavailable": #expect(update == .unavailable(reason: expect["reason"] as? String ?? ""), "\(label)")
        case "track":
            guard case let .track(t) = update else { Issue.record("\(label): expected a track, got \(update)"); return }
            if let v = expect["pkg"] as? String { #expect(t.pkg == v, "\(label) pkg") }
            if let v = expect["app"] as? String { #expect(t.app == v, "\(label) app") }
            if let v = expect["id"] as? String { #expect(t.id == v, "\(label) id") }
            if let v = expect["title"] as? String { #expect(t.title == v, "\(label) title") }
            if let v = expect["artist"] as? String { #expect(t.artist == v, "\(label) artist") }
            if let v = expect["album"] as? String { #expect(t.album == v, "\(label) album") }
            if let v = expect["state"] as? String { #expect(t.state.rawValue == v, "\(label) state") }
            if let v = expect["posMs"] as? Int { #expect(t.posMs == v, "\(label) pos") }
            if let v = expect["durMs"] as? Int { #expect(t.durMs == v, "\(label) dur") }
            if let v = expect["speed"] as? Double { #expect(t.speed == v, "\(label) speed") }
            if let v = expect["canPrev"] as? Bool { #expect(t.canPrev == v, "\(label) canPrev") }
            if let v = expect["canNext"] as? Bool { #expect(t.canNext == v, "\(label) canNext") }
            if let v = expect["canSeek"] as? Bool { #expect(t.canSeek == v, "\(label) canSeek") }
            if let v = expect["vol"] as? Int { #expect(t.vol == v, "\(label) vol") }
            if let v = expect["volMax"] as? Int { #expect(t.volMax == v, "\(label) volMax") }
        default:
            Issue.record("\(label): unknown expectation \(expect)")
        }
    }

    @Test func theSharedStateVectorsAreReadAsTheyPromise() throws {
        let all = try cases(kinds: ["state", "special", "absent", "parse_only"])
        #expect(all.count >= 8)
        for c in all {
            let wire = c["wire"] as? [String: Any] ?? [:]
            check(NowPlaying.parse(stat: wire), against: c["expect"] as? [String: Any] ?? [:], name(c))
        }
    }

    @Test func theCommandsAreBuiltTheWayThePhoneReadsThem() throws {
        let all = try cases(kinds: ["command"])
        #expect(all.count >= 7)
        for c in all {
            let expect = c["expect"] as? [String: Any] ?? [:]
            let command: MediaCommand
            switch expect["action"] as? String {
            case "toggle": command = .toggle
            case "play": command = .play
            case "pause": command = .pause
            case "next": command = .next
            case "prev": command = .prev
            case "seek": command = .seek(ms: expect["value"] as? Int ?? -1)
            case "vol": command = .volume(expect["value"] as? Int ?? -1)
            default: Issue.record("\(name(c)): unknown action"); continue
            }
            let built = try JSONSerialization.jsonObject(with: Data(command.statJSON.utf8)) as? NSDictionary
            let want = c["cmd"] as? NSDictionary
            #expect(built == want, "\(name(c)): built \(built ?? [:]) wanted \(want ?? [:])")
        }
    }

    @Test func theProgressInterpolationMatchesTheSharedVectors() throws {
        let all = try cases(kinds: ["position"])
        #expect(all.count >= 7)
        for c in all {
            let p = c["params"] as? [String: Any] ?? [:]
            let got = NowPlaying.position(
                state: NowPlaying.PlayState(rawValue: p["state"] as? String ?? "") ?? .stopped,
                posMs: p["pos"] as? Int ?? 0, durMs: p["dur"] as? Int ?? 0,
                speed: (p["speed"] as? NSNumber)?.doubleValue ?? 1, elapsedMs: p["dt_ms"] as? Int ?? 0)
            #expect(got == c["expect_ms"] as? Int, "\(name(c)): got \(got)")
        }
    }

    // MARK: - Mac-only behaviour

    private func playing(at t: Date, pos: Int = 10_000) -> NowPlaying {
        guard case let .track(n) = NowPlaying.parse(stat: [
            "media": ["on": true, "pkg": "p", "app": "A", "id": "i", "title": "T", "state": "playing",
                      "pos": pos, "dur": 200_000, "speed": 1.0, "can": ["prev": true, "next": true, "seek": true],
                      "vol": 5, "volMax": 15],
        ], receivedAt: t) else { fatalError("fixture should parse") }
        return n
    }

    @Test func progressAdvancesFromTheMomentTheStateArrived() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let n = playing(at: t0)
        #expect(n.positionMs(at: t0) == 10_000)
        #expect(n.positionMs(at: t0.addingTimeInterval(2.5)) == 12_500)
        // a clock that jumped backwards never makes the bar go before where it started
        #expect(n.positionMs(at: t0.addingTimeInterval(-3)) <= 10_000)
    }

    @Test func aPausedTrackDoesNotMove() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var n = playing(at: t0)
        n.state = .paused
        #expect(n.positionMs(at: t0.addingTimeInterval(60)) == 10_000)
    }

    @Test func coverArtNeedsAnIdAndAReadableImage() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        #expect(NowPlaying.art(stat: ["mediaArt": ["id": "abc", "jpeg": png]])?.id == "abc")
        #expect(NowPlaying.art(stat: ["mediaArt": ["id": "abc", "jpeg": png]])?.jpeg == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(NowPlaying.art(stat: ["mediaArt": ["id": "", "jpeg": png]]) == nil)
        #expect(NowPlaying.art(stat: ["mediaArt": ["id": "abc", "jpeg": "not base64!!"]]) == nil)
        #expect(NowPlaying.art(stat: ["mediaArt": ["id": "abc", "jpeg": ""]]) == nil)
        #expect(NowPlaying.art(stat: ["level": 80]) == nil)
    }

    @Test func aNegativeSeekOrVolumeIsClampedBeforeItLeavesTheMac() {
        #expect(MediaCommand.seek(ms: -50).wire["v"] as? Int == 0)
        #expect(MediaCommand.volume(-1).wire["v"] as? Int == 0)
    }
}
