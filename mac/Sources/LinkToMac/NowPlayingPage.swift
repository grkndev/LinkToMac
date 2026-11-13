import SwiftUI
import AppKit

/// The dashboard's **Now Playing** page: the phone's current track at full size — the cover, the
/// title, a seek bar with its knob, ⏮ ⏯ ⏭ and the phone's volume. Drawn to the macOS design
/// ("08 Media player").
///
/// What the design draws that is **not** here yet, because the phone doesn't send it: shuffle and
/// repeat, the "Other players on your phone" list, the output-device chip and "Open on Phone".
/// They need new `stat` fields (see `NowPlaying` / `protocol-vectors/stat-media.json`).
struct NowPlayingPage: View {
    let client: RelayClient
    /// False while another page is showing: the page stays mounted (so it doesn't rebuild when you
    /// come back) but its progress bar must not keep redrawing behind the scenes.
    var active = true

    /// Below this content width the cover sits above the text instead of beside it. The window's
    /// minimum content width (900 − the 240 pt sidebar) is under it; the default size is well over.
    private let sideBySideFrom: CGFloat = 720

    var body: some View {
        if client.isLinked, let track = client.nowPlaying {
            GeometryReader { geo in
                Group {
                    if geo.size.width >= sideBySideFrom {
                        wide(track)
                    } else {
                        ScrollView { narrow(track) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(alignment: .topLeading) { glow(track) }
        } else {
            empty
        }
    }

    // MARK: - Layouts

    private func wide(_ track: NowPlaying) -> some View {
        HStack(alignment: .top, spacing: 40) {
            coverColumn(track, size: 320)
                .padding(.top, 12)
            details(track)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 30).padding(.trailing, 36).padding(.top, 8).padding(.bottom, 28)
    }

    private func narrow(_ track: NowPlaying) -> some View {
        VStack(spacing: 24) {
            coverColumn(track, size: 240)
            details(track)
        }
        .padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func coverColumn(_ track: NowPlaying, size: CGFloat) -> some View {
        VStack(spacing: 18) {
            MediaCover(client: client, track: track, size: size, radius: size * 0.08)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(M3.primary)
                Text(sourceText(track)).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(M3.onSurfaceVariant)
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 26)
            .background(Capsule().fill(M3.surfaceContainer))
            .frame(maxWidth: size)
        }
    }

    private func details(_ track: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow(track))
                    .font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(M3.primary)
                Text(track.title)
                    .font(.system(size: 34, weight: .bold)).tracking(-0.7).foregroundStyle(M3.onSurface)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = subtitle(track) {
                    Text(sub).font(.system(size: 17)).foregroundStyle(M3.onSurfaceVariant).lineLimit(2)
                }
            }

            MediaProgress(client: client, track: track, barHeight: 5, remaining: true, timeSize: 12, ticking: active)

            HStack(spacing: 18) {
                Spacer(minLength: 0)
                MediaButton(symbol: "backward.fill", label: "Previous", size: 26, box: 52, enabled: track.canPrev) {
                    client.mediaCommand(.prev)
                }
                MediaPlayButton(track: track, diameter: 72, glyph: 29) { client.mediaCommand(.toggle) }
                MediaButton(symbol: "forward.fill", label: "Next", size: 26, box: 52, enabled: track.canNext) {
                    client.mediaCommand(.next)
                }
                Spacer(minLength: 0)
            }

            MediaVolume(client: client, track: track, iconSize: 14, barHeight: 4, spacing: 10)
                .frame(maxWidth: 420)
        }
        .padding(.top, 20)
    }

    // MARK: - Pieces

    /// A soft wash of the cover's colours behind the page's top right — the design's blurred
    /// gradient, here made from the real cover (the accent colour when the app gave none).
    private func glow(_ track: NowPlaying) -> some View {
        GeometryReader { geo in
            Group {
                if let image = mediaCoverImage(client, track) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [M3.primary, M3.primaryContainer], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: geo.size.width * 0.7, height: geo.size.height * 1.2)
            .clipped()
            .blur(radius: 90)
            .opacity(0.18)
            .position(x: geo.size.width * 0.65, y: geo.size.height * 0.3)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            M3IconBadge(icon: "speaker.slash", size: 56, fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
            Text(mediaEmptyText(client: client)).font(M3.titleMedium).foregroundStyle(M3.onSurface)
                .multilineTextAlignment(.center)
            Text("Start music, a podcast or a video on \(client.phoneName ?? "your phone") and control it here or from the menu bar.")
                .font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 52) // optical centre: the toolbar above takes space too
    }

    private func eyebrow(_ track: NowPlaying) -> String {
        switch track.state {
        case .playing: return "NOW PLAYING"
        case .buffering: return "BUFFERING"
        case .paused: return "PAUSED"
        case .stopped: return "STOPPED"
        }
    }

    /// "Lumen Coast · Harbor Lights", or whichever of the two the app gave.
    private func subtitle(_ track: NowPlaying) -> String? {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceText(_ track: NowPlaying) -> String {
        let phone = client.phoneName ?? "your phone"
        return track.app.isEmpty ? "On \(phone)" : "\(track.app) on \(phone)"
    }
}
