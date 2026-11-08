import SwiftUI
import AppKit

/// The menu-bar panel, drawn to the macOS design: the phone's status first, then what is in
/// flight and the last copy, a primary "Open Link to Mac" button, and — last, as in every Mac
/// menu — Settings… and Quit. It is read-only status plus those actions; every setting lives in the
/// Settings window. Width is fixed at 340; the height follows the content.
struct MenuPanel: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let onOpenWindow: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var targeted = false

    var body: some View {
        Group {
            if targeted || client.outgoingBatch != nil {
                // Dragging files over the panel (or sending): the panel becomes the drop target.
                PanelDropContent(phoneName: client.phoneName ?? "your phone", targeted: targeted,
                                 outgoing: client.outgoingBatch)
                    .padding(14)
                    .frame(width: 340)
            } else {
                content
            }
        }
        .phoneFileDrop(client: client, isTargeted: $targeted)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            identity
            if client.isLinked {
                chips
                if let clip = client.lastClip, !clip.isEmpty { lastCopy(clip) }
                if let incoming = client.incomingFile { incomingCard(incoming) }
                dropHint
            } else {
                waitingCard
            }
            openButton
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .frame(width: 340, alignment: .leading)
        .safeAreaInset(edge: .bottom, spacing: 0) { menuItems }
    }

    // MARK: - Identity

    private var identity: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(client.isLinked ? M3.primary : M3.surfaceContainerHigh)
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "iphone").font(.system(size: 21))
                    .foregroundStyle(client.isLinked ? M3.onPrimary : M3.onSurfaceVariant))
            VStack(alignment: .leading, spacing: 4) {
                Text(client.phoneName ?? "Android")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(M3.onSurface).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.text).font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Transport, phone battery and distance — each hidden until it has a real value.
    private var chips: some View {
        HStack(spacing: 6) {
            chip(icon: client.lanPeerConnected ? "wifi" : "cloud.fill", text: client.lanPeerConnected ? "LAN" : "Relay")
            if let level = client.phoneBatteryLevel {
                chip(icon: client.phoneCharging == true ? "battery.100.bolt" : "battery.75", text: "\(level)%")
            }
            if let distance = proximity.distanceText {
                chip(icon: "dot.radiowaves.left.and.right", text: distance.hasPrefix("Nearby") ? "Nearby" : distance)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(M3.onSurface)
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(M3.surfaceContainer))
    }

    // MARK: - Cards

    /// "Last copy" and the transfer card form one connected pair when both show.
    private func lastCopy(_ clip: String) -> some View {
        let shown = Self.display(clip)
        return HStack(spacing: 10) {
            DSCircleIcon(icon: "doc.on.clipboard", size: 30, fill: M3.surface, ink: M3.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Last copy").font(.system(size: 11.5)).foregroundStyle(M3.onSurfaceVariant)
                Text(shown).font(.system(size: 12.5)).foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(M3.outline)
        }
        .padding(.horizontal, 12).frame(height: 52)
        .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: client.incomingFile == nil ? 12 : 5,
                                           bottomTrailingRadius: client.incomingFile == nil ? 12 : 5, topTrailingRadius: 12,
                                           style: .continuous).fill(M3.surfaceContainer))
        .padding(.bottom, client.incomingFile == nil ? 0 : -9) // sit 3 pt above the transfer card
    }

    private func incomingCard(_ file: TransferProgress) -> some View {
        HStack(spacing: 10) {
            DSCircleIcon(icon: "arrow.down", size: 30, fill: M3.surface, ink: M3.primary)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(file.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(M3.onSurface)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("\(file.percent)%").font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant).monospacedDigit()
                }
                DSProgressBar(fraction: file.fraction, height: 3)
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(UnevenRoundedRectangle(topLeadingRadius: client.lastClip?.isEmpty == false ? 5 : 12,
                                           bottomLeadingRadius: 12, bottomTrailingRadius: 12,
                                           topTrailingRadius: client.lastClip?.isEmpty == false ? 5 : 12,
                                           style: .continuous).fill(M3.surfaceContainer))
    }

    private var dropHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 15)).foregroundStyle(M3.primary)
            Text("Drop files on the menu icon to send").font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 41)
    }

    private var waitingCard: some View {
        Text("Open Link to Mac on your phone, or check that both are on the same Wi-Fi. The menu icon stays dimmed until it connects.")
            .font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(M3.surfaceContainer))
    }

    private var openButton: some View {
        Button(action: onOpenWindow) {
            HStack(spacing: 8) {
                Text("Open Link to Mac").font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
            }
            .foregroundStyle(M3.onPrimary)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(Capsule().fill(M3.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Menu items

    private var menuItems: some View {
        VStack(spacing: 0) {
            Rectangle().fill(M3.outlineVariant).frame(height: 1)
            VStack(spacing: 0) {
                MenuItem(title: "Settings…", shortcut: "⌘,", action: onOpenSettings)
                MenuItem(title: "Quit Link to Mac", shortcut: "⌘Q", action: onQuit)
            }
            .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 10)
        }
    }

    private struct MenuItem: View {
        let title: String
        let shortcut: String
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                HStack {
                    Text(title).font(.system(size: 13)).foregroundStyle(M3.onSurface)
                    Spacer(minLength: 0)
                    Text(shortcut).font(.system(size: 12.5)).foregroundStyle(M3.outline)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? M3.surfaceContainerHigh : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    // MARK: - Derived

    /// A copied link reads better without its scheme ("github.com/…").
    private static func display(_ clip: String) -> String {
        let t = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where t.hasPrefix(prefix) { return String(t.dropFirst(prefix.count)) }
        return t
    }

    private struct StatusInfo { let text: String; let color: Color }

    private var status: StatusInfo {
        // A phone on either transport is a live link.
        if client.isLinked { return StatusInfo(text: "Connected", color: M3.success) }
        switch client.status {
        case .joined:
            return StatusInfo(text: "Waiting for phone", color: M3.warning)
        case .connecting, .connected:
            return StatusInfo(text: "Connecting…", color: M3.warning)
        case .disconnected:
            // No relay configured is the normal LAN-only setup, not an error.
            if !client.isRelayConfigured { return StatusInfo(text: "Waiting for phone", color: M3.warning) }
            return client.isActive
                ? StatusInfo(text: "Connecting…", color: M3.warning)
                : StatusInfo(text: "Disconnected", color: M3.onSurfaceVariant)
        case .error:
            if !client.isRelayConfigured { return StatusInfo(text: "Waiting for phone", color: M3.warning) }
            return StatusInfo(text: "Connection error", color: M3.error)
        }
    }
}
