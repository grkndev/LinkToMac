import SwiftUI

/// The pages in the sidebar. Calls and Photos are shown dimmed as "Soon" (no data source yet), so
/// they are not cases here.
enum DashPage: Hashable, CaseIterable {
    case overview, notifications, messages, nowPlaying, clipboard, files

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .notifications: return "Notifications"
        case .messages: return "Messages"
        case .nowPlaying: return "Now Playing"
        case .clipboard: return "Clipboard"
        case .files: return "Files"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .notifications: return "bell"
        case .messages: return "bubble.left"
        case .nowPlaying: return "play.circle"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "folder"
        }
    }
    var selectedIcon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .notifications: return "bell.fill"
        case .messages: return "bubble.left.fill"
        case .nowPlaying: return "play.circle.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .files: return "folder.fill"
        }
    }
}

extension DashPage {
    /// The pages the sidebar lists: Now Playing only while "Show what's playing" is on.
    static func visible(media: Bool) -> [DashPage] {
        allCases.filter { $0 != .nowPlaying || media }
    }
}

/// Navigation state, held outside the view so other code can drive the selected page.
@MainActor @Observable
final class DashboardNav {
    var page: DashPage = .overview
}

/// Root view of the dashboard window: a floating sidebar on the left and, beside it, a toolbar over
/// the selected page. Resizable (min 900 × 600); light and dark follow the system.
///
/// All pages stay mounted and are shown by opacity, so an open conversation or a scroll
/// position survives switching pages. Settings lives in its own window (⌘,).
struct DashboardView: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let nav: DashboardNav
    /// Read for `showMedia`: with media off the Now Playing page leaves the sidebar and the page list.
    let appearance: AppearanceStore
    @State private var dropTargeted = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(client: client, nav: nav, appearance: appearance)
                .frame(width: 232)
                .padding(.leading, 8).padding(.vertical, 8)
            VStack(spacing: 0) {
                toolbar
                pages
            }
            .overlay {
                // Covers the content area only — the sidebar stays put.
                if dropTargeted {
                    DropOverlay(phoneName: client.phoneName ?? "your phone").transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onAppear { SettingsOpener.shared.open = { openSettings() } }
        // A drop starts a transfer; show it where it is tracked.
        .onChange(of: client.outgoingBatch != nil) { _, sending in if sending { nav.page = .files } }
        // Turning media off while its page is open would leave an empty page behind.
        .onChange(of: appearance.showMedia) { _, on in if !on && nav.page == .nowPlaying { nav.page = .overview } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The titlebar is transparent and the content runs under it (the traffic lights float over
        // the sidebar), so the design's coordinates start at the window's very top edge.
        .ignoresSafeArea(.container, edges: .top)
        .background(M3.surface.ignoresSafeArea())
        // Drag a file anywhere onto the window to send it to the phone.
        .phoneFileDrop(client: client, isTargeted: $dropTargeted)
    }

    // MARK: - Toolbar

    /// 52 pt: title (+ a quiet subtitle) on the left, the page's actions on the right.
    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(nav.page.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(M3.onSurface)
                if let subtitle = toolbarSubtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(M3.outline)
                }
            }
            Spacer(minLength: 0)
            toolbarActions
            // Settings: the design reaches it from ⌘, and the menu panel; a button here makes it
            // findable from the window too.
            DSToolbarButton(icon: "gearshape") { openSettingsWindow() }.help("Settings (⌘,)")
        }
        .padding(.leading, 22).padding(.trailing, 20)
        .frame(height: 52)
    }

    private var toolbarSubtitle: String? {
        switch nav.page {
        case .messages:
            let n = client.conversations.count
            return n == 0 ? nil : "\(n) \(n == 1 ? "conversation" : "conversations")"
        case .clipboard:
            let n = client.clipHistory.count
            return n == 0 ? nil : "\(n) \(n == 1 ? "copy" : "copies") · kept until quit"
        default: return nil
        }
    }

    @ViewBuilder private var toolbarActions: some View {
        switch nav.page {
        case .messages:
            if !client.messages.isEmpty {
                DSToolbarButton(icon: "trash") { client.clearMessages() }.help("Clear messages")
            }
        case .clipboard:
            if !client.clipHistory.isEmpty {
                DSToolbarButton(icon: "trash", title: "Clear") { client.clearClipHistory() }
            }
        case .notifications:
            if !client.notifications.isEmpty {
                DSToolbarButton(icon: "trash", title: "Clear") { client.clearNotifications() }
            }
            DSToolbarButton(icon: "square.and.arrow.up", title: "Send Files…", style: .primary) {
                DashFilePicker.pickAndSend(client: client)
            }
        case .files:
            DSToolbarButton(icon: "folder.badge.plus", title: "Send Folder…") {
                DashFilePicker.pickAndSend(client: client, folders: true)
            }
            DSToolbarButton(icon: "square.and.arrow.up", title: "Send Files…", style: .primary) {
                DashFilePicker.pickAndSend(client: client)
            }
        case .overview:
            DSToolbarButton(icon: "square.and.arrow.up", title: "Send Files…", style: .primary) {
                DashFilePicker.pickAndSend(client: client)
            }
        case .nowPlaying:
            EmptyView() // the design's "Open on Phone" needs a phone command that doesn't exist yet
        }
    }

    // MARK: - Pages

    private var pages: some View {
        ZStack {
            ForEach(DashPage.visible(media: appearance.showMedia), id: \.self) { page in
                pageView(page)
                    .opacity(nav.page == page ? 1 : 0)
                    .allowsHitTesting(nav.page == page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pageView(_ page: DashPage) -> some View {
        switch page {
        case .overview:
            OverviewPage(client: client, proximity: proximity, appearance: appearance, onOpen: { nav.page = $0 })
        case .notifications:
            NotificationsPage(client: client)
        case .messages:
            MessagesPage(client: client)
        case .nowPlaying:
            NowPlayingPage(client: client, active: nav.page == .nowPlaying)
        case .clipboard:
            ClipHistoryScreen(client: client)
        case .files:
            FilesPage(client: client)
        }
    }
}

// MARK: - Sidebar

/// The floating sidebar: page links with counts, the roadmap pages dimmed as "Soon", and the
/// paired phone at the bottom. The traffic lights float over its top 44 pt.
struct DashboardSidebar: View {
    let client: RelayClient
    let nav: DashboardNav
    let appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44) // room for the traffic lights
            VStack(spacing: 2) {
                ForEach(DashPage.visible(media: appearance.showMedia), id: \.self) { page in item(page) }
            }
            .padding(.horizontal, 8).padding(.top, 4)

            Text("Coming later")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(M3.outline)
                .padding(.top, 16).padding(.horizontal, 18).padding(.bottom, 4)
            VStack(spacing: 2) {
                soonItem(icon: "phone", title: "Calls")
                soonItem(icon: "photo.on.rectangle", title: "Photos")
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
            phoneCard
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(M3.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(M3.outlineVariant, lineWidth: 0.5))
        )
    }

    private func count(for page: DashPage) -> Int {
        switch page {
        case .notifications: return client.notifications.count
        case .messages: return client.messages.filter { !$0.outgoing && !$0.read }.count
        default: return 0
        }
    }

    private func item(_ page: DashPage) -> some View {
        let selected = nav.page == page
        let n = count(for: page)
        return Button {
            nav.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? page.selectedIcon : page.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? M3.onPrimaryContainer : M3.primary)
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? M3.onPrimaryContainer : M3.onSurface)
                Spacer(minLength: 0)
                if n > 0 {
                    Text("\(n)").font(.system(size: 12)).foregroundStyle(M3.outline).monospacedDigit()
                }
                // A waveform while the phone is actually playing, like the design's Now Playing row.
                if page == .nowPlaying, client.isLinked, client.nowPlaying?.state == .playing {
                    Image(systemName: "waveform").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? M3.onPrimaryContainer : M3.primary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? M3.primaryContainer : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func soonItem(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
            Text(title).font(.system(size: 13.5))
            Spacer(minLength: 0)
            SoonPill()
        }
        .foregroundStyle(M3.outline)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    /// The paired phone, read-only: name, link state, transport and battery.
    private var phoneCard: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(M3.primary)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "iphone").font(.system(size: 15)).foregroundStyle(M3.onPrimary))
            VStack(alignment: .leading, spacing: 4) {
                Text(client.phoneName ?? "Android")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(M3.onSurface).lineLimit(1)
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(M3.surface)
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(M3.outlineVariant, lineWidth: 0.5))
        )
    }

    /// "● Connected · LAN · 82%" — values in the secondary colour, separators in the tertiary one.
    private var statusLine: some View {
        let parts: [String] = client.isLinked
            ? ["Connected", client.lanPeerConnected ? "LAN" : "Relay"] + (client.phoneBatteryLevel.map { ["\($0)%"] } ?? [])
            : ["Disconnected"]
        return HStack(spacing: 5) {
            Circle().fill(client.isLinked ? M3.success : M3.outline).frame(width: 8, height: 8)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").foregroundStyle(M3.outline) }
                Text(part).foregroundStyle(M3.onSurfaceVariant)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}
