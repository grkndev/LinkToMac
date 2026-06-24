import SwiftUI

/// Pushed from the dashboard's Clipboard tile. Redesigned in the M3 dashboard language: clips are
/// grouped by recency into **connected list groups** of two-line rows, each with a content-type
/// badge (link / command / phone / text), the clip over a "Kind · time" subtitle, and a tap-to-copy
/// affordance. **Phase 1: placeholder rows.** Phase 2 feeds this from a Mac-local ring of received
/// clips (no protocol change) and wires the tap to re-copy.
struct ClipHistoryScreen: View {
    private let today: [(text: String, time: String)] = [
        ("https://github.com/grkndev/LinkToMac", "2m"),
        ("Meeting moved to 3pm — conf room B", "18m"),
        ("npm run dev", "1h"),
    ]
    private let earlier: [(text: String, time: String)] = [
        ("ssh grkn@192.168.1.20", "Yesterday"),
        ("Lorem ipsum dolor sit amet, consectetur adipiscing", "Yesterday"),
        ("+90 555 123 45 67", "2d"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("TODAY", today)
                section("EARLIER", earlier)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M3.surface)
    }

    /// A section header + a connected group of clip rows.
    @ViewBuilder
    private func section(_ title: String, _ clips: [(text: String, time: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            M3SectionHeader(title)
            VStack(spacing: 3) {
                ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                    ClipRow(text: clip.text, time: clip.time,
                            position: groupPosition(index, count: clips.count))
                }
            }
        }
    }

    private func groupPosition(_ index: Int, count: Int) -> M3GroupPosition {
        if count == 1 { return .single }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }
}

/// The kind of a clip, inferred from its text — drives the row's badge icon, subtitle label, and
/// whether it renders monospaced. Reused verbatim once phase 2 feeds in real clips.
private enum ClipKind {
    case url, command, phone, text

    var icon: String {
        switch self {
        case .url: return "link"
        case .command: return "terminal.fill"
        case .phone: return "phone.fill"
        case .text: return "text.alignleft"
        }
    }
    var label: String {
        switch self {
        case .url: return "Link"
        case .command: return "Command"
        case .phone: return "Phone number"
        case .text: return "Text"
        }
    }
    /// Links and commands read better monospaced.
    var monospaced: Bool { self == .url || self == .command }

    static func infer(from raw: String) -> ClipKind {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return .url }
        let phoneChars = CharacterSet(charactersIn: "+0123456789 ()-")
        if s.count >= 7, s.unicodeScalars.allSatisfy(phoneChars.contains) { return .phone }
        for prefix in ["npm ", "ssh ", "git ", "cd ", "sudo ", "brew ", "bun ", "./"] where s.hasPrefix(prefix) {
            return .command
        }
        return .text
    }
}

/// One clip in a connected list group — leading content-type badge, the clip over a "Kind · time"
/// subtitle, and a trailing copy glyph that brightens on hover. The whole row is the copy button.
private struct ClipRow: View {
    let text: String
    let time: String
    var position: M3GroupPosition = .single
    @State private var hovering = false

    private var kind: ClipKind { ClipKind.infer(from: text) }
    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }
    private var titleFont: Font {
        kind.monospaced ? .system(size: 15, weight: .medium, design: .monospaced) : M3.titleMedium
    }

    var body: some View {
        Button {
            // Phase 2: re-copy `text` to the pasteboard.
        } label: {
            HStack(spacing: 14) {
                M3IconBadge(icon: kind.icon, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(titleFont)
                        .foregroundStyle(M3.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(kind.label) · \(time)")
                        .font(M3.bodyMedium)
                        .foregroundStyle(M3.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovering ? M3.onSurface : M3.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? M3.surfaceContainerHigh : M3.surfaceContainer))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
