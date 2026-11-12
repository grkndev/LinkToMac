import SwiftUI
import AppKit

/// What the phone is playing, drawn two ways: the Overview card (`MediaCard`) and the menu panel's
/// compact row (`MediaPanelRow`). Both read `RelayClient.nowPlaying` (the phone sends it when it
/// changes) and send `MediaCommand`s back through `RelayClient.mediaCommand`.
///
/// The progress bar is **not** driven by the phone's clock: `NowPlaying.positionMs(at:)` advances
/// from the moment the state arrived, and a `TimelineView` redraws it twice a second — only while
/// the track is actually playing, so a paused card costs nothing.

// MARK: - Shared pieces

/// "3:07", or "1:02:09" past an hour.
func mediaClock(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// The cover, or a tonal tile with a note when the app gave none.
private struct MediaCover: View {
    let client: RelayClient
    let track: NowPlaying
    var size: CGFloat

    private var image: NSImage? {
        guard client.mediaArtID == track.id, let data = client.mediaArtData else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Rectangle().fill(M3.secondaryContainer)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4))
                        .foregroundStyle(M3.onSecondaryContainer))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A thin bar you can click or drag. Shows `fraction`, follows the pointer while dragging and
/// reports the value **once, on release** — a seek or a volume change is one frame to the phone,
/// not a stream of them (the relay rate-limits a chatty peer).
private struct MediaBar: View {
    let fraction: Double
    var enabled = true
    var height: CGFloat = 4
    let onCommit: (Double) -> Void

    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = dragging ?? fraction
            ZStack(alignment: .leading) {
                Capsule().fill(M3.surfaceContainerHigh)
                Capsule().fill(enabled ? M3.primary : M3.outline)
                    .frame(width: geo.size.width * max(0, min(1, shown)))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled, geo.size.width > 0 else { return }
                        dragging = max(0, min(1, v.location.x / geo.size.width))
                    }
                    .onEnded { v in
                        guard enabled, geo.size.width > 0 else { dragging = nil; return }
                        let value = max(0, min(1, v.location.x / geo.size.width))
                        dragging = nil
                        onCommit(value)
                    }
            )
        }
        .frame(height: max(height, 16))
    }
}

private struct MediaButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 15
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: size * 2.2, height: size * 2.2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? M3.onSurface : M3.outline)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private func playPauseSymbol(_ t: NowPlaying) -> String {
    (t.state == .playing || t.state == .buffering) ? "pause.fill" : "play.fill"
}

/// The words for a card that has nothing to show, and what to do about it.
@MainActor private func mediaEmptyText(client: RelayClient) -> String {
    if !client.isLinked { return "Nothing playing" }
    switch client.mediaUnavailableReason {
    case "off": return "Mirror media is off on your phone"
    case "no-access": return "Allow notification access on your phone"
    case .some: return "Media isn't available on your phone"
    case .none: return "Nothing playing"
    }
}

// MARK: - Overview card

struct MediaCard: View {
    let client: RelayClient

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MediaCover(client: client, track: track, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(M3.onSurface)
                        .lineLimit(2)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                    }
                    if !track.app.isEmpty {
                        Text(track.app).font(.system(size: 11.5)).foregroundStyle(M3.outline).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            progress(track)
            controls(track)
            volume(track)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
    }

    private func progress(_ track: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = track.positionMs(at: track.state == .playing ? ctx.date : track.receivedAt)
            let known = track.durMs > 0
            VStack(spacing: 2) {
                MediaBar(fraction: known ? Double(pos) / Double(track.durMs) : 0, enabled: track.canSeek && known) { f in
                    client.mediaCommand(.seek(ms: Int(f * Double(track.durMs))))
                }
                HStack {
                    Text(mediaClock(pos))
                    Spacer()
                    Text(known ? mediaClock(track.durMs) : "Live")
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(M3.onSurfaceVariant)
            }
        }
    }

    private func controls(_ track: NowPlaying) -> some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            MediaButton(symbol: "backward.fill", label: "Previous", enabled: track.canPrev) { client.mediaCommand(.prev) }
            Button { client.mediaCommand(.toggle) } label: {
                Image(systemName: playPauseSymbol(track)).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(M3.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(M3.primary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.state == .playing ? "Pause" : "Play")
            MediaButton(symbol: "forward.fill", label: "Next", enabled: track.canNext) { client.mediaCommand(.next) }
            Spacer(minLength: 0)
        }
    }

    private func volume(_ track: NowPlaying) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(M3.onSurfaceVariant)
            MediaBar(fraction: track.volMax > 0 ? Double(track.vol) / Double(track.volMax) : 0, enabled: track.volMax > 0) { f in
                client.mediaCommand(.volume(Int((f * Double(track.volMax)).rounded())))
            }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(M3.onSurfaceVariant)
        }
        .accessibilityLabel("Phone volume")
    }
}

// MARK: - Menu panel row

/// One compact row for the menu-bar panel: cover, title/artist, ⏮ ⏯ ⏭. Absent when nothing plays.
struct MediaPanelRow: View {
    let client: RelayClient

    var body: some View {
        if client.isLinked, let track = client.nowPlaying {
            HStack(spacing: 10) {
                MediaCover(client: client, track: track, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(M3.onSurface).lineLimit(1)
                    Text(track.artist.isEmpty ? track.app : track.artist)
                        .font(.system(size: 11.5)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 4)
                MediaButton(symbol: "backward.fill", label: "Previous", size: 11, enabled: track.canPrev) { client.mediaCommand(.prev) }
                MediaButton(symbol: playPauseSymbol(track), label: track.state == .playing ? "Pause" : "Play", size: 13) {
                    client.mediaCommand(.toggle)
                }
                MediaButton(symbol: "forward.fill", label: "Next", size: 11, enabled: track.canNext) { client.mediaCommand(.next) }
            }
            .padding(.horizontal, 12).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(M3.surfaceContainer))
        }
    }
}
