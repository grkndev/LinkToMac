import SwiftUI
import AppKit

/// What the phone is playing, drawn three ways: the Now Playing page (`NowPlayingPage`), the Overview
/// mini player (`MediaCard`) and the menu panel's mini player (`MediaPanelRow`). All three read
/// `RelayClient.nowPlaying` (the phone sends it when it changes) and send `MediaCommand`s back
/// through `RelayClient.mediaCommand`; the pieces they share live here.
///
/// The progress bar is **not** driven by the phone's clock: `NowPlaying.positionMs(at:)` advances
/// from the moment the state arrived, and a `TimelineView` redraws it twice a second — only while
/// the track is actually playing (and its surface is on screen), so a paused card costs nothing.

// MARK: - Shared pieces

/// "3:07", or "1:02:09" past an hour.
func mediaClock(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

extension NowPlaying {
    /// Buffering counts as playing: the user pressed play and the phone is about to sound.
    var isPlaying: Bool { state == .playing || state == .buffering }

    /// "Playing", "Paused", … — the state in a word, for captions.
    var stateWord: String {
        switch state {
        case .playing: return "Playing"
        case .buffering: return "Buffering"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }
}

/// The decoded cover for `track`, only while it is the cover of **this** track (the art arrives in
/// its own frame, so for a moment after a track change the old cover is still cached).
@MainActor func mediaCoverImage(_ client: RelayClient, _ track: NowPlaying) -> NSImage? {
    guard client.mediaArtID == track.id, let data = client.mediaArtData else { return nil }
    return NSImage(data: data)
}

/// The cover, or a tonal tile with a note when the app gave none.
struct MediaCover: View {
    let client: RelayClient
    let track: NowPlaying
    var size: CGFloat
    /// Corner radius; the design uses a smaller ratio the bigger the cover gets.
    var radius: CGFloat?

    var body: some View {
        Group {
            if let image = mediaCoverImage(client, track) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Rectangle().fill(M3.secondaryContainer)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4))
                        .foregroundStyle(M3.onSecondaryContainer))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A thin bar you can click or drag. Shows `fraction`, follows the pointer while dragging and
/// reports the value **once, on release** — a seek or a volume change is one frame to the phone,
/// not a stream of them (the relay rate-limits a chatty peer).
///
/// `thumb` adds the design's 12 pt knob; `interactive: false` makes it a plain read-out (the
/// Overview mini player's progress).
struct MediaBar: View {
    let fraction: Double
    var enabled = true
    var height: CGFloat = 4
    var thumb = true
    var interactive = true
    var tint: Color = M3.primary
    let onCommit: (Double) -> Void

    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = max(0, min(1, dragging ?? fraction))
            let fill = enabled ? tint : M3.outline
            ZStack(alignment: .leading) {
                Capsule().fill(M3.surfaceContainerHigh).frame(height: height)
                Capsule().fill(fill).frame(width: geo.size.width * shown, height: height)
                if thumb && enabled {
                    Circle().fill(fill).frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .offset(x: max(0, min(geo.size.width - 12, geo.size.width * shown - 6)))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard interactive, enabled, geo.size.width > 0 else { return }
                        dragging = max(0, min(1, v.location.x / geo.size.width))
                    }
                    .onEnded { v in
                        guard interactive, enabled, geo.size.width > 0 else { dragging = nil; return }
                        let value = max(0, min(1, v.location.x / geo.size.width))
                        dragging = nil
                        onCommit(value)
                    },
                including: interactive ? .all : .subviews
            )
        }
        .frame(height: interactive || thumb ? max(height, 16) : height)
    }
}

/// A transport button: a glyph in a round hit area, no fill.
struct MediaButton: View {
    let symbol: String
    let label: String
    /// Glyph size in points.
    var size: CGFloat = 15
    /// Diameter of the (invisible) hit area.
    var box: CGFloat?
    var enabled = true
    let action: () -> Void

    var body: some View {
        let side = box ?? size * 2.2
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? M3.onSurface : M3.outline)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The filled play/pause circle, with the design's soft glow underneath.
struct MediaPlayButton: View {
    let track: NowPlaying
    let diameter: CGFloat
    let glyph: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(M3.onPrimary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(M3.primary))
                .shadow(color: M3.primary.opacity(0.35), radius: 8, y: 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(track.isPlaying ? "Pause" : "Play")
    }
}

/// Seek bar + the two times. Redraws twice a second while `ticking` and the track plays; frozen
/// otherwise (a paused card costs nothing, and neither does a page that isn't shown).
struct MediaProgress: View {
    enum Layout {
        /// Bar on top, times underneath (page, menu panel).
        case stacked
        /// `0:42 ▬▬▬ 3:58` on one line (Overview).
        case inline
    }

    let client: RelayClient
    let track: NowPlaying
    var layout: Layout = .stacked
    var barHeight: CGFloat = 4
    var thumb = true
    var interactive = true
    /// The right-hand time counts down ("−2:16") instead of showing the length.
    var remaining = false
    var timeSize: CGFloat = 11
    var ticking = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: ticking && track.state == .playing ? 0.5 : 3600)) { ctx in
            let pos = track.positionMs(at: track.state == .playing ? ctx.date : track.receivedAt)
            let known = track.durMs > 0
            let left = Text(mediaClock(pos))
            let right = Text(known ? (remaining ? "−" + mediaClock(track.durMs - pos) : mediaClock(track.durMs)) : "Live")
            let bar = MediaBar(fraction: known ? Double(pos) / Double(track.durMs) : 0,
                               enabled: track.canSeek && known, height: barHeight, thumb: thumb, interactive: interactive) { f in
                client.mediaCommand(.seek(ms: Int(f * Double(track.durMs))))
            }
            Group {
                switch layout {
                case .stacked:
                    VStack(spacing: 2) {
                        bar
                        HStack { left; Spacer(); right }
                    }
                case .inline:
                    HStack(spacing: 8) { left; bar; right }
                }
            }
            .font(.system(size: timeSize)).monospacedDigit().foregroundStyle(M3.outline)
        }
    }
}

/// Phone volume: a speaker, a slider, a louder speaker. Disabled when the phone reports no range.
struct MediaVolume: View {
    let client: RelayClient
    let track: NowPlaying
    var iconSize: CGFloat = 13
    var barHeight: CGFloat = 4
    var spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "speaker.fill").font(.system(size: iconSize))
            MediaBar(fraction: track.volMax > 0 ? Double(track.vol) / Double(track.volMax) : 0,
                     enabled: track.volMax > 0, height: barHeight, tint: M3.onSurfaceVariant) { f in
                client.mediaCommand(.volume(Int((f * Double(track.volMax)).rounded())))
            }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: iconSize))
        }
        .foregroundStyle(M3.onSurfaceVariant)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phone volume")
    }
}

/// The words for a card that has nothing to show, and what to do about it.
@MainActor func mediaEmptyText(client: RelayClient) -> String {
    if !client.isLinked { return "Nothing playing" }
    switch client.mediaUnavailableReason {
    case "off": return "Mirror media is off on your phone"
    case "no-access": return "Allow notification access on your phone"
    case .some: return "Media isn't available on your phone"
    case .none: return "Nothing playing"
    }
}

// MARK: - Overview mini player

/// The Overview's media tile: cover, "Spotify · Playing", title, artist and ⏮ ⏯ ⏭, with a read-only
/// progress line underneath. Tapping the cover/text opens the Now Playing page.
struct MediaCard: View {
    let client: RelayClient
    var onOpen: (() -> Void)?

    var body: some View {
        // Hidden while the link is down: the last track is stale then, and the controls can't reach the phone.
        if client.isLinked, let track = client.nowPlaying {
            playing(track)
        } else {
            empty
        }
    }

    private var empty: some View {
        HStack(spacing: 12) {
            DSCircleIcon(icon: "music.note")
            Text(mediaEmptyText(client: client))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(M3.onSurfaceVariant)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
    }

    private func playing(_ track: NowPlaying) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { onOpen?() } label: {
                    HStack(spacing: 12) {
                        MediaCover(client: client, track: track, size: 56, radius: 10)
                            .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform").font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(M3.primary)
                                Text(caption(track)).lineLimit(1)
                            }
                            .font(.system(size: 11.5)).foregroundStyle(M3.outline)
                            Text(track.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(M3.onSurface)
                                .lineLimit(1)
                            if !track.artist.isEmpty {
                                Text(track.artist).font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
                .accessibilityLabel("\(track.title), \(track.stateWord). Open Now Playing")

                HStack(spacing: 2) {
                    MediaButton(symbol: "backward.fill", label: "Previous", size: 14, box: 30, enabled: track.canPrev) {
                        client.mediaCommand(.prev)
                    }
                    MediaPlayButton(track: track, diameter: 36, glyph: 14) { client.mediaCommand(.toggle) }
                    MediaButton(symbol: "forward.fill", label: "Next", size: 14, box: 30, enabled: track.canNext) {
                        client.mediaCommand(.next)
                    }
                }
            }
            MediaProgress(client: client, track: track, layout: .inline, barHeight: 3,
                          thumb: false, interactive: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
    }

    private func caption(_ track: NowPlaying) -> String {
        track.app.isEmpty ? track.stateWord : "\(track.app) · \(track.stateWord)"
    }
}

// MARK: - Menu panel mini player

/// The menu panel's player: cover + source/title/artist, a seek bar, ⏮ ⏯ ⏭ and the volume. Absent
/// when nothing plays (the panel just doesn't have the row).
struct MediaPanelRow: View {
    let client: RelayClient

    var body: some View {
        if client.isLinked, let track = client.nowPlaying {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    MediaCover(client: client, track: track, size: 64, radius: 12)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    VStack(alignment: .leading, spacing: 2) {
                        if !track.app.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform").font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(M3.primary)
                                Text(track.app).lineLimit(1)
                            }
                            .font(.system(size: 11.5)).foregroundStyle(M3.outline)
                        }
                        Text(track.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(M3.onSurface)
                            .lineLimit(1)
                        if !track.artist.isEmpty {
                            Text(track.artist).font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                MediaProgress(client: client, track: track)
                HStack(spacing: 14) {
                    MediaButton(symbol: "backward.fill", label: "Previous", size: 17, box: 36, enabled: track.canPrev) {
                        client.mediaCommand(.prev)
                    }
                    MediaPlayButton(track: track, diameter: 48, glyph: 19) { client.mediaCommand(.toggle) }
                    MediaButton(symbol: "forward.fill", label: "Next", size: 17, box: 36, enabled: track.canNext) {
                        client.mediaCommand(.next)
                    }
                }
                MediaVolume(client: client, track: track, iconSize: 12, barHeight: 3, spacing: 8)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(M3.surfaceContainer))
        }
    }
}
