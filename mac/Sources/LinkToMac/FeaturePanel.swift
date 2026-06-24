import SwiftUI

/// Right column of the dashboard: an M3 filter-chip tab bar over a list of two-line M3 rows (leading
/// circular tonal badge + title + subtitle + trailing time), mirroring the mobile app's list idiom.
/// **Phase 1: pure placeholder** (roadmap features). Selecting a tab swaps the row icon + content.
struct FeaturePanel: View {
    private struct Tab {
        let icon: String
        let title: String
        let rowIcon: String
        let rows: [(title: String, subtitle: String, time: String)]
    }

    private let tabs: [Tab] = [
        Tab(icon: "bell.fill", title: "Notifications", rowIcon: "bell.fill", rows: [
            ("Slack", "grkn: ship the dashboard redesign today", "now"),
            ("Gmail", "Your build finished successfully", "2m"),
            ("Calendar", "Standup in 15 minutes", "12m"),
            ("WhatsApp", "Mom: are you coming for dinner?", "28m"),
            ("GitHub", "PR #42 was approved and merged", "1h"),
            ("Spotify", "Discover Weekly is ready", "3h"),
        ]),
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
            VStack(spacing: 3) {
                let rows = tabs[selected].rows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    M3Row(icon: tabs[selected].rowIcon,
                          title: row.title, subtitle: row.subtitle, trailing: row.time,
                          position: groupPosition(index, count: rows.count))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where a cell sits in a connected group — shared by the tab strip and the row list (drives corner shaping).
    private func groupPosition(_ index: Int, count: Int) -> M3GroupPosition {
        if count == 1 { return .single }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }
}
