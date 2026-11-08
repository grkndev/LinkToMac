import SwiftUI

/// The Clipboard page: a centred 680 pt column — an info banner, then the Mac-local ring of clips
/// received from the phone (`RelayClient.clipHistory`) in Today / Earlier connected lists. Clicking
/// a row puts it back on this Mac's clipboard. (The count and Clear live in the toolbar.)
struct ClipHistoryScreen: View {
    let client: RelayClient

    private struct ClipGroup { let title: String; let entries: [RelayClient.ClipEntry] }

    private var groups: [ClipGroup] {
        let cal = Calendar.current
        let today = client.clipHistory.filter { cal.isDateInToday($0.date) }
        let earlier = client.clipHistory.filter { !cal.isDateInToday($0.date) }
        var result: [ClipGroup] = []
        if !today.isEmpty { result.append(ClipGroup(title: "Today", entries: today)) }
        if !earlier.isEmpty { result.append(ClipGroup(title: "Earlier", entries: earlier)) }
        return result
    }

    var body: some View {
        if client.clipHistory.isEmpty {
            DashEmptyState(icon: "doc.on.clipboard", title: "No clips yet",
                           message: "Copies received from your phone will appear here.")
        } else {
            DashColumnPage(width: 680) {
                VStack(alignment: .leading, spacing: 18) {
                    infoBanner
                    ForEach(groups, id: \.title) { group in section(group) }
                }
            }
        }
    }

    private var infoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill").font(.system(size: 16))
            Text("Copies from your phone land here. Click a row to put it back on this Mac's clipboard.")
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(M3.onPrimaryContainer)
        .padding(.horizontal, 14).frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.primaryContainer))
    }

    @ViewBuilder
    private func section(_ group: ClipGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(M3.onSurfaceVariant).padding(.horizontal, 4)
            VStack(spacing: 3) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    ClipRow(text: entry.text, time: DashTime.relative(entry.date), isImage: entry.isImage,
                            position: dashGroupPosition(index, count: group.entries.count)) {
                        // We don't retain image bytes, so re-copying an image row would clobber the
                        // clipboard with the literal "[Image]" string — only re-copy real text.
                        if !entry.isImage { client.recopy(entry.text) }
                    }
                }
            }
        }
    }
}

/// The kind of a clip, inferred from its text — drives the row's badge icon, subtitle label, and
/// whether it renders monospaced.
enum ClipKind {
    case url, command, phone, text, image

    var icon: String {
        switch self {
        case .url: return "link"
        case .command: return "terminal.fill"
        case .phone: return "phone.fill"
        case .text: return "text.alignleft"
        case .image: return "photo"
        }
    }
    var label: String {
        switch self {
        case .url: return "Link"
        case .command: return "Command"
        case .phone: return "Phone number"
        case .text: return "Text"
        case .image: return "Image"
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

/// One clip in a connected list: a tonal icon for its kind, the clip over a "Kind · time" subtitle,
/// and a copy glyph (a green check for a moment after a click). Links and commands read monospaced.
struct ClipRow: View {
    let text: String
    let time: String
    var isImage: Bool = false
    var position: M3GroupPosition = .single
    let onCopy: () -> Void
    @State private var copied = false

    private var kind: ClipKind { isImage ? .image : ClipKind.infer(from: text) }

    var body: some View {
        Button(action: copy) {
            DSListRow(
                title: text,
                titleFont: kind.monospaced
                    ? .system(size: 12.5, weight: .semibold, design: .monospaced)
                    : .system(size: 13.5, weight: .semibold),
                subtitle: copied ? "Copied to clipboard"
                    : (isImage ? "Image · \(time) · shown only, not stored" : "\(kind.label) · \(time)"),
                subtitleColor: copied ? M3.success : M3.onSurfaceVariant,
                position: position, interactive: !isImage
            ) {
                DSCircleIcon(icon: kind.icon)
            } trailing: {
                // No glyph for images — we don't keep the bytes, so the row is display-only.
                if !isImage {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: copied ? 15 : 14, weight: copied ? .semibold : .regular))
                        .foregroundStyle(copied ? M3.success : M3.outline)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Re-copy, then flash a check + "Copied to clipboard" for about a second.
    private func copy() {
        guard !isImage else { return }
        onCopy()
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut) { copied = false }
        }
    }
}
