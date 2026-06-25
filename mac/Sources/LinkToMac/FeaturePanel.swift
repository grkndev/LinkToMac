import SwiftUI

/// Right column of the dashboard: an M3 filter-chip tab bar over a list of two-line M3 rows (leading
/// circular tonal badge + title + subtitle + trailing time), mirroring the mobile app's list idiom.
///
/// **The Notifications tab is real** (phase 2): it renders `client.notifications` — mirrored phone
/// notifications received over the `note` channel — with the posting app's icon, newest-first, plus
/// an empty state and a Clear action. **Messages / Calls / Photos stay placeholder** (roadmap, no
/// data source). Selecting a tab swaps the content.
struct FeaturePanel: View {
    let client: RelayClient

    private struct Tab {
        let icon: String
        let title: String
        let rowIcon: String
        let rows: [(title: String, subtitle: String, time: String)]
    }

    /// Tab metadata. The Notifications tab (index 0) is driven by real data; its sample `rows` are
    /// unused (the body special-cases index 0). The other three remain hardcoded placeholders.
    private let tabs: [Tab] = [
        Tab(icon: "bell.fill", title: "Notifications", rowIcon: "bell.fill", rows: []),
        Tab(icon: "message.fill", title: "Messages", rowIcon: "message.fill", rows: [
            ("Ada", "Sounds good, see you then!", "now"),
            ("Deniz", "Did you push the fix?", "5m"),
            ("Team", "Kerem: deploying to preview", "18m"),
            ("Mert", "Thanks for the help 🙏", "40m"),
            ("Zeynep", "Call me when you're free", "2h"),
            ("Can", "Sent the invoice", "5h"),
        ]),
        Tab(icon: "phone.fill", title: "Calls", rowIcon: "phone.fill", rows: [
            ("Ada Yılmaz", "Incoming • 4m 12s", "now"),
            ("Deniz K.", "Outgoing • 1m 03s", "32m"),
            ("Unknown", "Missed call", "1h"),
            ("Mert A.", "Outgoing • 8m 47s", "3h"),
            ("Zeynep", "Incoming • 22s", "yesterday"),
            ("Can D.", "Missed call", "yesterday"),
        ]),
        Tab(icon: "photo.fill", title: "Photos", rowIcon: "photo.fill", rows: [
            ("IMG_2048.HEIC", "Shared from S24 Ultra", "now"),
            ("Screenshot", "1080 × 2400 · PNG", "9m"),
            ("IMG_2041.HEIC", "Camera · 12 MP", "1h"),
            ("Sunset.jpg", "Shared album", "4h"),
            ("IMG_2033.HEIC", "Camera · 12 MP", "yesterday"),
            ("Receipt.pdf", "Document scan", "2d"),
        ]),
    ]
    @State private var selected = 0

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    M3Tab(icon: tab.icon, title: tab.title, selected: selected == index,
                          position: groupPosition(index, count: tabs.count)) {
                        selected = index
                    }
                }
            }
            if selected == 0 {
                notificationsContent
            } else {
                placeholderRows
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notifications (real)

    @ViewBuilder
    private var notificationsContent: some View {
        let items = client.notifications
        if items.isEmpty {
            emptyState
        } else {
            HStack {
                Spacer(minLength: 0)
                Button { client.clearNotifications() } label: {
                    Text("Clear").font(M3.labelLarge).foregroundStyle(M3.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, note in
                    M3Row(icon: "bell.fill",
                          iconImage: note.icon,
                          title: note.app,
                          subtitle: subtitle(for: note),
                          trailing: Self.relativeFormatter.localizedString(for: note.date, relativeTo: Date()),
                          position: groupPosition(index, count: items.count))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            M3IconBadge(icon: "bell.slash", size: 56,
                        fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
            Text("No notifications yet").font(M3.titleMedium).foregroundStyle(M3.onSurface)
            Text("Notifications from your phone appear here.")
                .font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private func subtitle(for note: RelayClient.NotificationEntry) -> String {
        if !note.title.isEmpty && !note.text.isEmpty { return "\(note.title): \(note.text)" }
        return note.text.isEmpty ? note.title : note.text
    }

    // MARK: - Placeholder tabs (roadmap)

    private var placeholderRows: some View {
        VStack(spacing: 3) {
            let rows = tabs[selected].rows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                M3Row(icon: tabs[selected].rowIcon,
                      title: row.title, subtitle: row.subtitle, trailing: row.time,
                      position: groupPosition(index, count: rows.count))
            }
        }
    }

    /// Where a cell sits in a connected group — shared by the tab strip and the row list (drives corner shaping).
    private func groupPosition(_ index: Int, count: Int) -> M3GroupPosition {
        if count == 1 { return .single }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }
}
