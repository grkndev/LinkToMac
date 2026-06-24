import SwiftUI
import AppKit

/// The menu-bar popover panel shown by `MenuBarExtra(...).menuBarExtraStyle(.window)`.
///
/// A soft, native **quick glance**: the paired Mac's identity + a live status pill, the last
/// received copy, and a footer. **All settings now live in the dashboard's Settings screen** —
/// this panel is read-only status plus "Open Window…" / "Quit". `RelayClient` is `@Observable`,
/// so reading its properties here makes the panel re-render live as the status / last clip change.
struct MenuPanel: View {
    let client: RelayClient
    /// Opens the main dashboard window (every setting — clipboard, proximity, pairing, relay,
    /// connect, login item, updates, about, unpair — now lives there).
    let onOpenWindow: () -> Void

    private var deviceName: String { Host.current().localizedName ?? "This Mac" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            lastClipCard
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !client.isRelayConfigured {
                    // Reassure the user the link still works without a relay URL set.
                    Text("No relay set — local network only")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Last clip (read-only glance)

    @ViewBuilder
    private var lastClipCard: some View {
        if let clip = client.lastClip, !clip.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("CLIPBOARD")
                Card {
                    InfoRow(icon: "doc.on.clipboard", title: "Last copy", value: clip)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: onOpenWindow) {
                Label("Open Window…", systemImage: "macwindow").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 0)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    // MARK: - Derived status

    private struct StatusInfo { let text: String; let color: Color }

    private var status: StatusInfo {
        // A phone on the LAN is a live connection regardless of the relay's state — show it first.
        if client.lanPeerConnected {
            return StatusInfo(text: "Connected · Android online · LAN", color: .green)
        }
        switch client.status {
        case .joined:
            return client.peerOnline
                ? StatusInfo(text: "Connected · Android online · Relay", color: .green)
                : StatusInfo(text: "Waiting for Android · Relay", color: .orange)
        case .connecting, .connected:
            return StatusInfo(text: "Connecting…", color: .orange)
        case .disconnected:
            // No relay configured is the normal LAN-only setup, not an error.
            if !client.isRelayConfigured {
                return StatusInfo(text: "LAN-direct · waiting for phone", color: .orange)
            }
            return client.isActive
                ? StatusInfo(text: "Connecting…", color: .orange)
                : StatusInfo(text: "Disconnected", color: .gray)
        case .error:
            if !client.isRelayConfigured {
                return StatusInfo(text: "LAN-direct · waiting for phone", color: .orange)
            }
            return StatusInfo(text: "Connection error", color: .red)
        }
    }
}
