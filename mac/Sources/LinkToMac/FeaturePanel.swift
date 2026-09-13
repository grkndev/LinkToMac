import SwiftUI

/// Right column of the dashboard: an M3 filter-chip tab bar over a list of two-line M3 rows (leading
/// circular tonal badge + title + subtitle + trailing time), mirroring the mobile app's list idiom.
///
/// **Notifications (index 0)** renders `client.notifications` — mirrored phone notifications over the
/// `note` channel. **Messages (index 1)** renders `client.conversations` — mirrored phone SMS over the
/// `sms` channel — as a thread list that drills into a chat-bubble view. **Calls / Photos stay
/// placeholder** (roadmap, no data source). Selecting a tab swaps the content.
struct FeaturePanel: View {
    let client: RelayClient

    private struct Tab {
        let icon: String
        let title: String
        let rowIcon: String
        let rows: [(title: String, subtitle: String, time: String)]
    }

    /// Tab metadata. Notifications (0) and Messages (1) are driven by real data (the body
    /// special-cases them); their sample `rows` are unused. Calls / Photos remain placeholders.
    private let tabs: [Tab] = [
        Tab(icon: "bell.fill", title: "Notifications", rowIcon: "bell.fill", rows: []),
        Tab(icon: "message.fill", title: "Messages", rowIcon: "message.fill", rows: []),
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
    /// The conversation currently drilled into on the Messages tab (its `threadKey`), or nil for the list.
    @State private var selectedThread: String?
    /// Current page (0-based) of the Notifications / Messages thread lists. Both lists are paged so a
    /// large history never overflows the fixed-height dashboard window (it has no outer scroll). Held
    /// per list; clamped on read so a shrinking list (Clear / dedup) can't leave us past the last page.
    @State private var notifPage = 0
    @State private var msgPage = 0
    /// Rows per page — sized to fit the right column inside the fixed 1280×760 window.
    private static let pageSize = 7

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
                        if index != 1 { selectedThread = nil }
                    }
                }
            }
            if selected == 0 {
                notificationsContent
            } else if selected == 1 {
                messagesContent
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
            emptyState(icon: "bell.slash", title: "No notifications yet",
                       message: "Notifications from your phone appear here.")
        } else {
            let pageCount = Self.pageCount(items.count)
            let page = min(notifPage, pageCount - 1)
            let slice = Self.page(items, page)
            clearBar { client.clearNotifications() }
            VStack(spacing: 3) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { index, note in
                    M3Row(icon: "bell.fill",
                          iconImage: note.icon,
                          title: note.app,
                          subtitle: subtitle(for: note),
                          trailing: Self.relativeFormatter.localizedString(for: note.date, relativeTo: Date()),
                          position: groupPosition(index, count: slice.count))
                }
            }
            pager(page: page, pageCount: pageCount) { notifPage = $0 }
        }
    }

    private func subtitle(for note: RelayClient.NotificationEntry) -> String {
        if !note.title.isEmpty && !note.text.isEmpty { return "\(note.title): \(note.text)" }
        return note.text.isEmpty ? note.title : note.text
    }

    // MARK: - Messages (real)

    @ViewBuilder
    private var messagesContent: some View {
        let convos = client.conversations
        if let threadKey = selectedThread, let convo = convos.first(where: { $0.id == threadKey }) {
            threadView(convo)
        } else if convos.isEmpty {
            emptyState(icon: "message", title: "No messages yet",
                       message: "Text messages from your phone appear here.")
        } else {
            let pageCount = Self.pageCount(convos.count)
            let page = min(msgPage, pageCount - 1)
            let slice = Self.page(convos, page)
            clearBar { client.clearMessages() }
            VStack(spacing: 3) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { index, convo in
                    Button {
                        selectedThread = convo.id
                    } label: {
                        // `latest` is nil only for a (never-observed) empty Conversation; fall
                        // back to blank/"now" rather than force-unwrapping.
                        M3Row(icon: "message.fill",
                              title: convo.display,
                              subtitle: convo.latest.map(preview) ?? " ",
                              trailing: convo.latest.map { Self.relativeFormatter.localizedString(for: $0.date, relativeTo: Date()) } ?? "",
                              position: groupPosition(index, count: slice.count))
                    }
                    .buttonStyle(.plain)
                }
            }
            pager(page: page, pageCount: pageCount) { msgPage = $0 }
        }
    }

    /// Latest-message preview for a thread row; outgoing texts are prefixed so direction reads at a glance.
    private func preview(_ m: RelayClient.MessageEntry) -> String {
        m.body.isEmpty ? " " : (m.outgoing ? "You: \(m.body)" : m.body)
    }

    /// A thread can be replied to only when every message in it shares one address — the SMS
    /// store doesn't cleanly model group-thread participants today, so a mixed-address thread
    /// (a group conversation) hides the composer rather than guessing recipients.
    private func isOneToOne(_ convo: RelayClient.Conversation) -> Bool {
        Set(convo.messages.map(\.addr)).filter { !$0.isEmpty }.count <= 1
    }

    @ViewBuilder
    private func threadView(_ convo: RelayClient.Conversation) -> some View {
        let address = convo.id.hasPrefix("t") ? (convo.latest?.addr ?? "") : convo.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    selectedThread = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(M3.onSurfaceVariant)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(M3.surfaceContainer))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                M3IconBadge(icon: "message.fill", size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.display).font(M3.titleMedium).foregroundStyle(M3.onSurface).lineLimit(1)
                    if !address.isEmpty && address != convo.display {
                        Text(address).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            // Chat order: open anchored to the NEWEST message (the bottom — `messages` is
            // oldest→newest) and follow live deltas, like every other messaging UI.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(convo.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    if let last = convo.messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: convo.latest?.id) {
                    if let last = convo.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            if isOneToOne(convo) {
                ReplyComposer(address: address) { body in
                    client.sendReply(addr: address, body: body)
                }
            }
        }
    }

    /// Inline text field + send button pinned under a 1:1 thread, iMessage-style.
    private struct ReplyComposer: View {
        let address: String
        let onSend: (String) -> Void
        @State private var draft = ""

        var body: some View {
            HStack(spacing: 8) {
                TextField("Text Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(M3.bodyLarge)
                    .foregroundStyle(M3.onSurface)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: M3.corLarge, style: .continuous).fill(M3.surfaceContainer))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? M3.onSurfaceVariant : M3.primary)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
            }
        }

        private func send() {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !address.isEmpty else { return }
            onSend(text)
            draft = ""
        }
    }

    /// One chat bubble — outgoing trailing/`primaryContainer`, incoming leading/`surfaceContainerHigh`.
    private struct MessageBubble: View {
        let message: RelayClient.MessageEntry

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f
        }()

        var body: some View {
            HStack {
                if message.outgoing { Spacer(minLength: 48) }
                VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                    Text(message.body)
                        .font(M3.bodyLarge)
                        .foregroundStyle(message.outgoing ? M3.onPrimaryContainer : M3.onSurface)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: M3.corLarge, style: .continuous)
                                .fill(message.outgoing ? M3.primaryContainer : M3.surfaceContainerHigh)
                        )
                        .opacity(message.status == .sending ? 0.6 : 1)
                    HStack(spacing: 4) {
                        if message.status == .sending {
                            Image(systemName: "clock").font(.system(size: 10))
                            Text("Sending…").font(.system(size: 11))
                        } else if case let .failed(reason) = message.status {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10))
                            Text("Not delivered (\(reason))").font(.system(size: 11))
                        } else {
                            Text(Self.timeFormatter.string(from: message.date)).font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(message.status.isFailed ? M3.error : M3.onSurfaceVariant)
                }
                if !message.outgoing { Spacer(minLength: 48) }
            }
        }
    }

    // MARK: - Shared

    private func clearBar(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Text("Clear").font(M3.labelLarge).foregroundStyle(M3.onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            M3IconBadge(icon: icon, size: 56,
                        fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
            Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface)
            Text(message).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: - Pagination

    /// Number of pages for `total` items (≥ 1, so an empty list still reads as "1 / 1" — though
    /// callers show the empty state instead of paging in that case).
    private static func pageCount(_ total: Int) -> Int {
        max(1, (total + pageSize - 1) / pageSize)
    }

    /// The `page`-th slice (0-based) of `items`, at most `pageSize` long.
    private static func page<T>(_ items: [T], _ page: Int) -> [T] {
        Array(items.dropFirst(page * pageSize).prefix(pageSize))
    }

    /// Footer pager — hidden when there's only one page. `set` receives the new (clamped) page index.
    @ViewBuilder
    private func pager(page: Int, pageCount: Int, set: @escaping (Int) -> Void) -> some View {
        if pageCount > 1 {
            M3Pager(page: page, pageCount: pageCount,
                    onPrev: { set(max(0, page - 1)) },
                    onNext: { set(min(pageCount - 1, page + 1)) })
        }
    }

    /// A compact page control: ‹ prev · "p / n" · next › in the M3 tonal-badge language. Ends disable.
    private struct M3Pager: View {
        let page: Int
        let pageCount: Int
        let onPrev: () -> Void
        let onNext: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                button("chevron.left", enabled: page > 0, action: onPrev)
                Text("\(page + 1) / \(pageCount)")
                    .font(M3.labelLarge).foregroundStyle(M3.onSurfaceVariant)
                    .frame(minWidth: 52)
                button("chevron.right", enabled: page < pageCount - 1, action: onNext)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }

        private func button(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(enabled ? M3.onSecondaryContainer : M3.onSurfaceVariant.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(enabled ? M3.secondaryContainer : M3.surfaceContainer))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
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
