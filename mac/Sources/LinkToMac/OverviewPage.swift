import SwiftUI
import AppKit

/// The dashboard's home page (Overview): the paired phone's status card, quick actions, anything
/// arriving right now, and short "recent" lists that lead to the full pages. Every measurement is
/// taken from the macOS design (894 pt wide at the default window size; it fills what it gets).
struct OverviewPage: View {
    let client: RelayClient
    /// BLE proximity to the phone, measured by this Mac. Only has a value while auto-lock is on and
    /// the phone is in range.
    let proximity: ProximityMonitor
    let onOpen: (DashPage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                actions
                if let incoming = client.incomingFile { incomingRow(incoming) }
                WeightedHStack(weights: [1.25, 1], spacing: 16) {
                    recentNotifications
                    VStack(alignment: .leading, spacing: 12) {
                        recentCopies
                        mediaCard
                    }
                }
            }
            .padding(.top, 4).padding(.bottom, 24)
            .padding(.leading, 22).padding(.trailing, 24)
        }
    }

    // MARK: - Status card

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(M3.primary)
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "iphone").font(.system(size: 30)).foregroundStyle(M3.onPrimary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.phoneName ?? "Android")
                        .font(.system(size: 26, weight: .bold)).lineLimit(1)
                    Text("Paired phone").font(.system(size: 13)).opacity(0.8)
                }
                .padding(.top, 6)
                Spacer(minLength: 8)
                statusPill
            }
            HStack(spacing: 4) {
                tile(icon: transportIcon, label: "Link", value: transportDetail, position: .first)
                tile(icon: batteryIcon, label: "Phone battery", value: batteryText, position: .middle)
                tile(icon: "dot.radiowaves.left.and.right", label: "Distance",
                     value: proximity.distanceText ?? "Auto-lock off", position: .last)
            }
        }
        .foregroundStyle(M3.onPrimaryContainer)
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(M3.primaryContainer))
    }

    private var statusPill: some View {
        let tint = client.isLinked ? M3.success : M3.outline
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
                .background(Circle().fill(tint.opacity(0.22)).frame(width: 14, height: 14))
            Text(client.isLinked ? "Connected" : "Disconnected")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(M3.onSurface)
        .padding(.leading, 11).padding(.trailing, 13)
        .frame(height: 30)
        .background(Capsule().fill(M3.surface))
    }

    private func tile(icon: String, label: String, value: String, position: M3GroupPosition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).frame(height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12)).opacity(0.75)
                Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92, alignment: .topLeading)
        .background(
            position.shape(axis: .horizontal, big: 18, small: 6)
                .fill(M3.onPrimaryContainer.opacity(0.08))
        )
    }

    private var transportIcon: String {
        if client.lanPeerConnected { return "wifi" }
        if client.peerOnline { return "cloud.fill" }
        return "wifi.slash"
    }
    private var transportDetail: String {
        if client.lanPeerConnected { return "LAN · same Wi-Fi" }
        if client.peerOnline { return "Relay" }
        return "Offline"
    }
    private var batteryText: String {
        guard let level = client.phoneBatteryLevel else { return "—" }
        return client.phoneCharging == true ? "\(level)% · charging" : "\(level)%"
    }
    private var batteryIcon: String {
        guard let level = client.phoneBatteryLevel else { return "battery.0" }
        if client.phoneCharging == true { return "battery.100.bolt" }
        switch level {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 35..<60: return "battery.50"
        case 10..<35: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: - Quick actions

    private var actions: some View {
        HStack(spacing: 3) {
            Button { DashFilePicker.pickAndSend(client: client) } label: {
                action(icon: "square.and.arrow.up", title: "Send Files…", detail: "Or drop them anywhere",
                       position: .first)
            }
            .buttonStyle(.plain)
            Button { onOpen(.clipboard) } label: {
                action(icon: "doc.on.clipboard", title: "Clipboard", detail: clipboardDetail, position: .middle)
            }
            .buttonStyle(.plain)
            action(icon: "lock", title: "Lock Phone", soon: true, position: .middle)
            action(icon: "airplayvideo", title: "Cast Screen", soon: true, position: .last)
        }
    }

    private var clipboardDetail: String {
        let n = client.clipHistory.count
        return n == 0 ? "No copies yet" : "\(n) \(n == 1 ? "copy" : "copies")"
    }

    private func action(icon: String, title: String, detail: String? = nil, soon: Bool = false,
                        position: M3GroupPosition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Circle()
                .fill(soon ? M3.surfaceContainerHigh : M3.surface)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 15))
                    .foregroundStyle(soon ? M3.onSurfaceVariant : M3.primary))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(M3.onSurface).lineLimit(1)
                Spacer(minLength: 0)
                if soon { SoonPill() }
                else if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92)
        .background(position.shape(axis: .horizontal).fill(M3.surfaceContainer))
        .opacity(soon ? 0.55 : 1)
        .contentShape(position.shape(axis: .horizontal))
    }

    // MARK: - Incoming transfer

    /// Inline rather than the full-window overlay the *outgoing* direction uses: an incoming
    /// transfer isn't something the user just asked for, so covering the window would be wrong.
    private func incomingRow(_ file: TransferProgress) -> some View {
        HStack(spacing: 12) {
            DSCircleIcon(icon: "arrow.down", fill: M3.primaryContainer, ink: M3.onPrimaryContainer)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Receiving \(file.name)").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(file.percent)%").font(.system(size: 13)).foregroundStyle(M3.onSurfaceVariant).monospacedDigit()
                }
                DSProgressBar(fraction: file.fraction, height: 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
    }

    // MARK: - Recents

    private var recentNotifications: some View {
        let items = Array(client.notifications.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent notifications", link: "Show all") { onOpen(.notifications) }
            if items.isEmpty {
                emptyLine("Notifications from your phone appear here.")
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, note in
                        NotificationRow(note: note, position: dashGroupPosition(index, count: items.count))
                    }
                }
            }
        }
    }

    private var recentCopies: some View {
        let items = Array(client.clipHistory.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent copies", link: "History") { onOpen(.clipboard) }
            if items.isEmpty {
                emptyLine("Copies received from your phone appear here.")
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                        ClipRow(text: entry.text, time: DashTime.relative(entry.date), isImage: entry.isImage,
                                position: dashGroupPosition(index, count: items.count)) {
                            if !entry.isImage { client.recopy(entry.text) }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, link: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(M3.onSurfaceVariant)
            Spacer(minLength: 0)
            Button(action: action) {
                Text(link).font(.system(size: 12.5, weight: .medium)).foregroundStyle(M3.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
    }

    // MARK: - Media (roadmap)

    private var mediaCard: some View {
        HStack(spacing: 12) {
            DSCircleIcon(icon: "music.note")
            Text("Media controls").font(.system(size: 13, weight: .semibold)).foregroundStyle(M3.onSurface)
            Spacer(minLength: 0)
            SoonPill()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
        .opacity(0.6)
    }
}

/// A mirrored notification row: the source app's icon in a rounded square (a tinted letter tile when
/// the phone sent no icon), app name over "title: text", and the time.
struct NotificationRow: View {
    let note: RelayClient.NotificationEntry
    var position: M3GroupPosition = .single

    var body: some View {
        let tint = M3.tint(for: note.app)
        DSListRow(title: note.app, subtitle: NotificationsPage.subtitle(for: note), position: position) {
            if let icon = note.icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.fill)
                    .frame(width: 36, height: 36)
                    .overlay(Text(String(note.app.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint.ink))
            }
        } trailing: {
            Text(DashTime.relative(note.date)).font(.system(size: 12)).foregroundStyle(M3.outline)
        }
    }
}

/// The design's thin progress bar: a tonal track with a primary fill.
struct DSProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(M3.surfaceContainerHigh)
                Capsule().fill(M3.primary).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// The small "Soon" tag that marks roadmap features.
struct SoonPill: View {
    var body: some View {
        Text("Soon")
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(M3.onSurfaceVariant)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(M3.surfaceContainerHigh))
    }
}

/// "Send Files…": a standard open panel (files and folders, several at once) whose result goes
/// through the same batch path as a drop.
@MainActor
enum DashFilePicker {
    static func pickAndSend(client: RelayClient, folders: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = folders
            ? "Choose folders to send to \(client.phoneName ?? "your phone")."
            : "Choose files or folders to send to \(client.phoneName ?? "your phone")."
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in client.sendFilesToPhone(panel.urls) }
        }
    }
}
