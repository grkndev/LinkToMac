import SwiftUI

/// Relative time ("2m", "1h") shared by the dashboard pages.
@MainActor
enum DashTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    static func relative(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Where a cell sits in a connected group — drives the large/small corner shaping.
func dashGroupPosition(_ index: Int, count: Int) -> M3GroupPosition {
    if count == 1 { return .single }
    if index == 0 { return .first }
    if index == count - 1 { return .last }
    return .middle
}

/// A centred empty state: tonal badge, title, one line of help. Fills the page and centres in it,
/// so every page's empty state sits in the same place.
struct DashEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            M3IconBadge(icon: icon, size: 56, fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
            Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface)
            Text(message).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 52) // optical centre: the toolbar above takes space too
    }
}

/// A scrolling page whose content is a centred column (`width` is the design's, e.g. 680 or 760).
struct DashColumnPage<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
                .padding(.top, 6).padding(.bottom, 24)
                .padding(.horizontal, 22)
        }
    }
}

// MARK: - Notifications page

/// Mirrored phone notifications (`client.notifications`, newest first) as one connected list.
struct NotificationsPage: View {
    let client: RelayClient

    var body: some View {
        let items = client.notifications
        if items.isEmpty {
            DashEmptyState(icon: "bell.slash", title: "No notifications yet",
                           message: "Notifications from your phone appear here.")
        } else {
            DashColumnPage(width: 680) {
                LazyVStack(spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, note in
                        NotificationRow(note: note, position: dashGroupPosition(index, count: items.count))
                    }
                }
            }
        }
    }

    static func subtitle(for note: RelayClient.NotificationEntry) -> String {
        if !note.title.isEmpty && !note.text.isEmpty { return "\(note.title): \(note.text)" }
        return note.text.isEmpty ? note.title : note.text
    }
}

// MARK: - Messages page

/// Mirrored phone SMS: a 322 pt conversation list (search, tinted avatars) and the open
/// conversation beside it. Replies only for 1:1 threads; a failed message offers Retry, one still
/// sending is dimmed. Measurements are the design's.
struct MessagesPage: View {
    let client: RelayClient
    @State private var selectedThread: String?
    @State private var query = ""

    private var filtered: [RelayClient.Conversation] {
        let all = client.conversations
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { convo in
            convo.display.localizedCaseInsensitiveContains(q)
                || (convo.latest?.addr.localizedCaseInsensitiveContains(q) ?? false)
                || convo.messages.contains { $0.body.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        let all = client.conversations
        if all.isEmpty {
            DashEmptyState(icon: "message", title: "No messages yet",
                           message: "Text messages from your phone appear here.")
        } else {
            let open = all.first(where: { $0.id == selectedThread }) ?? all.first
            HStack(spacing: 0) {
                threadList(open: open?.id)
                    .frame(width: 322)
                Rectangle().fill(M3.outlineVariant).frame(width: 0.5)
                if let open { ConversationView(client: client, convo: open).id(open.id) }
            }
        }
    }

    private func threadList(open: String?) -> some View {
        let rows = filtered
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(M3.outline)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(M3.onSurface)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(M3.surfaceContainer))
            .padding(.leading, 20).padding(.trailing, 14).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { convo in
                        Button { selectedThread = convo.id } label: {
                            ThreadRow(convo: convo, selected: convo.id == open)
                        }
                        .buttonStyle(.plain)
                    }
                    if rows.isEmpty {
                        Text("No matches").font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.bottom, 8)
            }
        }
    }

    private struct ThreadRow: View {
        let convo: RelayClient.Conversation
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Avatar(name: convo.display, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(convo.display)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(M3.onSurface).lineLimit(1)
                        Spacer(minLength: 4)
                        if let latest = convo.latest {
                            Text(DashTime.relative(latest.date)).font(.system(size: 12)).foregroundStyle(M3.outline)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(convo.latest.map { $0.outgoing ? "You: \($0.body)" : $0.body } ?? " ")
                            .font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                        Spacer(minLength: 0)
                        if convo.unread > 0 { Circle().fill(M3.primary).frame(width: 8, height: 8) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? M3.primaryContainer : (hovering ? M3.surfaceContainer : Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
        }
    }

    /// Initials in a tinted circle (a contact photo is not mirrored). Two words → both initials
    /// ("Mert Kaya" → MK); one word → its first two letters ("Ayşe" → Ay); a number → its prefix.
    struct Avatar: View {
        let name: String
        var size: CGFloat = 38
        private var initials: String {
            let words = name.split(separator: " ")
            guard let first = words.first else { return "#" }
            if !(first.first?.isLetter ?? false) { return String(first.prefix(3)) }
            if words.count >= 2 { return String(words.prefix(2).compactMap(\.first)).uppercased() }
            return String(first.prefix(1)).uppercased() + String(first.dropFirst().prefix(1))
        }
        var body: some View {
            let tint = M3.tint(for: name)
            Circle().fill(tint.fill).frame(width: size, height: size)
                .overlay(Text(initials).font(.system(size: size > 34 ? 14 : 12, weight: .semibold))
                    .foregroundStyle(tint.ink))
        }
    }

    // MARK: Conversation

    private struct ConversationView: View {
        let client: RelayClient
        let convo: RelayClient.Conversation

        private var address: String { convo.id.hasPrefix("t") ? (convo.latest?.addr ?? "") : convo.id }
        /// Replying needs one recipient: a thread whose messages span several addresses is a group.
        private var isOneToOne: Bool { Set(convo.messages.map(\.addr)).filter { !$0.isEmpty }.count <= 1 }
        private var subtitle: String {
            let via = client.phoneName.map { "via \($0)" } ?? "via your phone"
            return address.isEmpty || address == convo.display ? via : "\(address) · \(via)"
        }

        /// Messages split by calendar day, oldest first.
        private var days: [(label: String, messages: [RelayClient.MessageEntry])] {
            let cal = Calendar.current
            var out: [(Date, [RelayClient.MessageEntry])] = []
            for m in convo.messages {
                let day = cal.startOfDay(for: m.date)
                if let i = out.firstIndex(where: { $0.0 == day }) { out[i].1.append(m) } else { out.append((day, [m])) }
            }
            return out.map { (Self.dayLabel($0.0), $0.1) }
        }

        private static func dayLabel(_ day: Date) -> String {
            let cal = Calendar.current
            if cal.isDateInToday(day) { return "Today" }
            if cal.isDateInYesterday(day) { return "Yesterday" }
            return day.formatted(date: .abbreviated, time: .omitted)
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Avatar(name: convo.display, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(convo.display).font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(M3.onSurface).lineLimit(1)
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(M3.outline).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Rectangle().fill(M3.outlineVariant).frame(height: 0.5)

                // A short conversation sits at the bottom, next to the composer, and a long one opens
                // on the newest message.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(days, id: \.label) { day in
                                Text(day.label).font(.system(size: 11.5)).foregroundStyle(M3.outline)
                                    .frame(maxWidth: .infinity).frame(height: 22)
                                ForEach(day.messages) { message in
                                    MessageBubble(message: message) { client.retryMessage(id: message.id) }
                                        .id(message.id)
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: convo.latest?.id) {
                        if let last = convo.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                }
                if isOneToOne {
                    ReplyComposer(address: address) { body in client.sendReply(addr: address, body: body) }
                        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
                }
            }
        }
    }

    private struct ReplyComposer: View {
        let address: String
        let onSend: (String) -> Void
        @State private var draft = ""
        private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var body: some View {
            HStack(spacing: 8) {
                TextField("Text Message · SMS", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(M3.onSurface)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(M3.field))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(M3.outlineVariant, lineWidth: 0.5))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(empty ? M3.onSurfaceVariant : M3.onPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(empty ? M3.surfaceContainerHigh : M3.primary))
                }
                .buttonStyle(.plain)
                .disabled(empty || address.isEmpty)
            }
        }

        private func send() {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !address.isEmpty else { return }
            onSend(text)
            draft = ""
        }
    }

    /// One bubble: 18 pt corners with a 6 pt "tail" corner on the sender's side.
    private struct MessageBubble: View {
        let message: RelayClient.MessageEntry
        let onRetry: () -> Void

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f
        }()

        private var shape: UnevenRoundedRectangle {
            message.outgoing
                ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                         bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6,
                                         bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
        }

        var body: some View {
            HStack {
                if message.outgoing { Spacer(minLength: 80) }
                VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                    Text(message.body)
                        .font(.system(size: 13.5))
                        .foregroundStyle(message.outgoing ? M3.onPrimaryContainer : M3.onSurface)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(shape.fill(message.outgoing ? M3.primaryContainer : M3.surfaceContainerHigh))
                        .opacity(message.status == .sending ? 0.6 : 1)
                    footer
                }
                if !message.outgoing { Spacer(minLength: 80) }
            }
        }

        @ViewBuilder private var footer: some View {
            if message.status == .sending {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text("Sending…").font(.system(size: 11.5))
                }
                .foregroundStyle(M3.outline)
            } else if case let .failed(reason) = message.status {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                    Text("Not delivered ·").font(.system(size: 11.5))
                    Button("Retry", action: onRetry).buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(M3.error)
                .help(reason)
            } else {
                Text(Self.timeFormatter.string(from: message.date)).font(.system(size: 12)).foregroundStyle(M3.outline)
            }
        }
    }
}
