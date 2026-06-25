import SwiftUI
import AppKit

/// The menu-bar popover panel shown by `MenuBarExtra(...).menuBarExtraStyle(.window)`.
///
/// A compact **phone-identity glance** in the same Material 3 language as the dashboard / mobile
/// app: the paired phone's render + name, a live connection status, and tonal transport / battery
/// chips — followed by the last received copy and an Open-Window / Quit footer. **All settings live
/// in the dashboard's Settings screen**; this panel is read-only status. `RelayClient` is
/// `@Observable`, so reading its properties here makes the panel re-render live.
struct MenuPanel: View {
    let client: RelayClient
    /// Opens the main dashboard window (every setting — clipboard, proximity, pairing, relay,
    /// connect, login item, updates, about, unpair — now lives there).
    let onOpenWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            footer
            identity
            lastClipRow
            
        }
        .padding(16)
        .frame(width: 340)
        .background(M3.surface)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Identity (phone render + name + status + chips)

    private var identity: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("PhoneRender")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 138)

            VStack(alignment: .leading, spacing: 8) {
                Text(client.phoneName ?? "Android")
                    .font(M3.headline(20))
                    .foregroundStyle(M3.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 7) {
                    Circle().fill(status.color).frame(width: 9, height: 9)
                    Text(status.text)
                        .font(M3.bodyMedium)
                        .foregroundStyle(M3.onSurfaceVariant)
                        .lineLimit(1)
                }
                statusChips
            }
            Spacer(minLength: 0)
        }
    }

    /// Transport + phone battery, hidden until each value is real. (This Mac's own battery isn't
    /// shown — we're already on the Mac.)
    private var statusChips: some View {
        HStack(spacing: 8) {
            M3Chip(icon: transportIcon, text: transportText)
            if let level = client.phoneBatteryLevel {
                M3Chip(icon: Self.batteryIcon(level, charging: client.phoneCharging ?? false),
                       text: "\(level)%")
            }
        }
        .padding(.top, 2)
    }

    private var transportIcon: String {
        if client.lanPeerConnected { return "wifi" }
        if client.peerOnline { return "cloud.fill" }
        return "wifi.slash"
    }
    private var transportText: String {
        if client.lanPeerConnected { return "LAN" }
        if client.peerOnline { return "Relay" }
        return "Offline"
    }

    /// SF Symbol for a battery level (+ charging bolt), matching the system battery glyph steps.
    private static func batteryIcon(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 35..<60: return "battery.50"
        case 10..<35: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: - Last clip (read-only glance)

    @ViewBuilder
    private var lastClipRow: some View {
        if let clip = client.lastClip, !clip.isEmpty {
            HStack(spacing: 12) {
                M3IconBadge(icon: "doc.on.clipboard", size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Last copy")
                        .font(M3.bodyMedium)
                        .foregroundStyle(M3.onSurfaceVariant)
                    Text(clip)
                        .font(M3.bodyMedium)
                        .foregroundStyle(M3.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: M3.corLarge, style: .continuous)
                    .fill(M3.surfaceContainer)
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: onOpenWindow) {
                Label("Open Window", systemImage: "macwindow")
                    .font(M3.labelLarge)
                    .foregroundStyle(M3.primary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit")
                    .font(M3.labelLarge)
                    .foregroundStyle(M3.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Derived status

    private struct StatusInfo { let text: String; let color: Color }

    /// Amber for transient connecting/waiting states (M3 has no amber role; mirrors the mobile app).
    private static let warn = Color(m3: 0xF39C12)

    private var status: StatusInfo {
        // A phone on either transport is a live link — show "Connected" the way Image #9 does.
        if client.isLinked { return StatusInfo(text: "Connected", color: M3.success) }
        switch client.status {
        case .joined:
            return StatusInfo(text: "Waiting for phone", color: Self.warn)
        case .connecting, .connected:
            return StatusInfo(text: "Connecting…", color: Self.warn)
        case .disconnected:
            // No relay configured is the normal LAN-only setup, not an error.
            if !client.isRelayConfigured {
                return StatusInfo(text: "Waiting for phone", color: Self.warn)
            }
            return client.isActive
                ? StatusInfo(text: "Connecting…", color: Self.warn)
                : StatusInfo(text: "Disconnected", color: M3.onSurfaceVariant)
        case .error:
            if !client.isRelayConfigured {
                return StatusInfo(text: "Waiting for phone", color: Self.warn)
            }
            return StatusInfo(text: "Connection error", color: M3.error)
        }
    }
}
