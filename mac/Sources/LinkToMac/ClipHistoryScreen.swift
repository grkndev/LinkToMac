import SwiftUI

/// Pushed from the dashboard's Clipboard tile. Shows the Mac-local ring of clips received from the
/// phone (`RelayClient.clipHistory`), grouped by recency into **connected list groups** of two-line
/// rows: a content-type badge (link / command / phone / text), the clip over a "Kind · time"
/// subtitle, and a hover-reactive copy glyph. Tapping a row re-copies it to the Mac pasteboard.
struct ClipHistoryScreen: View {
    let client: RelayClient

    private struct ClipGroup { let title: String; let entries: [RelayClient.ClipEntry] }

    /// Split the history into TODAY / EARLIER, preserving newest-first order within each.
    private var groups: [ClipGroup] {
        let cal = Calendar.current
        let today = client.clipHistory.filter { cal.isDateInToday($0.date) }
        let earlier = client.clipHistory.filter { !cal.isDateInToday($0.date) }
        var result: [ClipGroup] = []
        if !today.isEmpty { result.append(ClipGroup(title: "TODAY", entries: today)) }
        if !earlier.isEmpty { result.append(ClipGroup(title: "EARLIER", entries: earlier)) }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if client.clipHistory.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                        section(group, showClear: index == 0)
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M3.surface)
    }

    @ViewBuilder
    private func section(_ group: ClipGroup, showClear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                M3SectionHeader(group.title)
                Spacer()
                if showClear {
                    Button { client.clearClipHistory() } label: {
                        Text("Clear").font(M3.labelLarge).foregroundStyle(M3.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 3) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    ClipRow(text: entry.text, time: Self.relative(entry.date), isImage: entry.isImage,
                            position: groupPosition(index, count: group.entries.count)) {
                        // We don't retain image bytes, so re-copying an image row would clobber the
                        // clipboard with the literal "[Image]" string — only re-copy real text.
                        if !entry.isImage { client.recopy(entry.text) }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            M3IconBadge(icon: "doc.on.clipboard", size: 64,
                        fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
            Text("No clips yet").font(M3.titleLarge).foregroundStyle(M3.onSurface)
            Text("Copies received from your phone will appear here.")
                .font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func groupPosition(_ index: Int, count: Int) -> M3GroupPosition {
        if count == 1 { return .single }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The kind of a clip, inferred from its text — drives the row's badge icon, subtitle label, and
/// whether it renders monospaced.
private enum ClipKind {
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

/// One clip in a connected list group — leading content-type badge, the clip over a "Kind · time"
/// subtitle, and a trailing copy glyph that brightens on hover. The whole row re-copies on tap.
private struct ClipRow: View {
    let text: String
    let time: String
    var isImage: Bool = false
    var position: M3GroupPosition = .single
    let onCopy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private var kind: ClipKind { isImage ? .image : ClipKind.infer(from: text) }
    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }
    private var titleFont: Font {
        kind.monospaced ? .system(size: 15, weight: .medium, design: .monospaced) : M3.titleMedium
    }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 14) {
                M3IconBadge(icon: kind.icon, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(titleFont)
                        .foregroundStyle(M3.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(copied ? "Copied to clipboard" : "\(kind.label) · \(time)")
                        .font(M3.bodyMedium)
                        .foregroundStyle(copied ? M3.success : M3.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // No re-copy glyph for images — we don't keep the bytes, so the row is display-only.
                if !isImage {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(copied ? M3.success : (hovering ? M3.onSurface : M3.onSurfaceVariant))
                        .contentTransition(.symbolEffect(.replace))
                }
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

    /// Re-copy, then flash a checkmark + "Copied" for a moment so the tap clearly registers.
    private func copy() {
        guard !isImage else { return } // image rows are display-only (no retained bytes to re-copy)
        onCopy()
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut) { copied = false }
        }
    }
}
