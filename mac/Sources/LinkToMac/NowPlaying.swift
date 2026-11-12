import Foundation

/// What the phone is playing, as the Mac shows it. The phone sends the state **when it changes**
/// (a track, a pause, a seek, the volume), never a ticking position: `positionMs(at:)` advances the
/// progress locally from the moment the state arrived. The relay would not take a frame a second,
/// and a Mac that reads "3:02" the instant the phone says "3:02" is as good as one told every second.
///
/// Foundation only, so the test target compiles it. The wire format is pinned by
/// `protocol-vectors/stat-media.json`, which the phone's `MediaStateTest` runs too.
struct NowPlaying: Equatable, Sendable {
    enum PlayState: String, Sendable {
        case playing, paused, buffering, stopped
    }

    var pkg: String
    var app: String
    /// Changes with the track; cover art is cached under it.
    var id: String
    var title: String
    var artist: String
    var album: String
    var state: PlayState
    /// Position at `receivedAt`, in ms.
    var posMs: Int
    /// Length in ms, 0 when unknown (a live stream).
    var durMs: Int
    var speed: Double
    var canPrev: Bool
    var canNext: Bool
    var canSeek: Bool
    var vol: Int
    var volMax: Int
    var receivedAt: Date

    /// Where playback is at `now`.
    func positionMs(at now: Date) -> Int {
        let elapsed = Int((now.timeIntervalSince(receivedAt) * 1000).rounded())
        return Self.position(state: state, posMs: posMs, durMs: durMs, speed: speed, elapsedMs: elapsed)
    }

    /// `pos + elapsed × speed` while playing, frozen while paused/buffering/stopped; never negative
    /// and never past `dur` (when it is known).
    static func position(state: PlayState, posMs: Int, durMs: Int, speed: Double, elapsedMs: Int) -> Int {
        var pos = posMs
        if state == .playing { pos += Int((Double(elapsedMs) * speed).rounded()) }
        if pos < 0 { pos = 0 }
        if durMs > 0, pos > durMs { pos = durMs }
        return pos
    }

    /// What one inbound `stat` says about media.
    enum Update: Equatable, Sendable {
        /// No (usable) media field: the card keeps showing what it shows. Battery and proximity
        /// stats arrive all the time and must not blank it.
        case absent
        /// `"media": null`: nothing is playing any more.
        case cleared
        /// The phone can't report media; `reason` ("no-access") says what to fix.
        case unavailable(reason: String)
        case track(NowPlaying)
    }

    static func parse(stat: [String: Any], receivedAt: Date = Date()) -> Update {
        guard let raw = stat["media"] else { return .absent }
        if raw is NSNull { return .cleared }
        guard let media = raw as? [String: Any] else { return .absent }

        if (media["on"] as? Bool) == false {
            return .unavailable(reason: media["reason"] as? String ?? "")
        }
        let can = media["can"] as? [String: Any] ?? [:]
        return .track(NowPlaying(
            pkg: media["pkg"] as? String ?? "",
            app: media["app"] as? String ?? "",
            id: media["id"] as? String ?? "",
            title: media["title"] as? String ?? "",
            artist: media["artist"] as? String ?? "",
            album: media["album"] as? String ?? "",
            state: PlayState(rawValue: media["state"] as? String ?? "") ?? .stopped,
            posMs: int(media["pos"]),
            durMs: int(media["dur"]),
            speed: (media["speed"] as? NSNumber)?.doubleValue ?? 1,
            canPrev: can["prev"] as? Bool ?? false,
            canNext: can["next"] as? Bool ?? false,
            canSeek: can["seek"] as? Bool ?? false,
            vol: int(media["vol"]),
            volMax: int(media["volMax"]),
            receivedAt: receivedAt
        ))
    }

    /// The cover art that rides in its own stat (`mediaArt`), once per track.
    static func art(stat: [String: Any]) -> (id: String, jpeg: Data)? {
        guard let art = stat["mediaArt"] as? [String: Any],
              let id = art["id"] as? String, !id.isEmpty,
              let b64 = art["jpeg"] as? String, let data = Data(base64Encoded: b64), !data.isEmpty
        else { return nil }
        return (id, data)
    }

    private static func int(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }
}

/// What the Mac asks the phone to do. Sent as the `mediaCmd` field of a small `stat`.
enum MediaCommand: Equatable, Sendable {
    case toggle, play, pause, next, prev
    case seek(ms: Int)
    case volume(Int)

    /// The `mediaCmd` object.
    var wire: [String: Any] {
        switch self {
        case .toggle: return ["a": "toggle"]
        case .play: return ["a": "play"]
        case .pause: return ["a": "pause"]
        case .next: return ["a": "next"]
        case .prev: return ["a": "prev"]
        case let .seek(ms): return ["a": "seek", "v": max(0, ms)]
        case let .volume(level): return ["a": "vol", "v": max(0, level)]
        }
    }

    /// The whole `stat` plaintext: `{"mediaCmd": {...}}`.
    var statJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: ["mediaCmd": wire], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
