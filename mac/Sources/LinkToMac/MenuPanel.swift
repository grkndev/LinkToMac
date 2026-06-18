import SwiftUI
import AppKit

/// The menu-bar popover panel shown by `MenuBarExtra(...).menuBarExtraStyle(.window)`.
///
/// A soft, native card: the paired Mac's identity + a live status pill, a CLIPBOARD group
/// with the real `.switch` toggle and the last received copy, a general settings group, and
/// a footer. `RelayClient` is `@Observable`, so reading its properties here makes the panel
/// re-render live as the relay status / last clip change.
struct MenuPanel: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let onShowPairing: () -> Void
    let onShowServerSettings: () -> Void
    let onShowAbout: () -> Void
    let onCheckForUpdates: () -> Void

    private var deviceName: String { Host.current().localizedName ?? "This Mac" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            clipboardCard
            securityCard
            generalCard
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

    // MARK: - Clipboard

    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("CLIPBOARD")
            Card {
                ToggleRow(
                    icon: "arrow.up.arrow.down",
                    title: "Send copies to Android",
                    isOn: Binding(get: { client.sendToAndroid }, set: { client.sendToAndroid = $0 })
                )
                if let clip = client.lastClip, !clip.isEmpty {
                    RowDivider()
                    InfoRow(icon: "doc.on.clipboard", title: "Last copy", value: clip)
                }
            }
        }
    }

    // MARK: - Security

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("SECURITY")
            Card {
                ToggleRow(
                    icon: "lock.laptopcomputer",
                    title: "Lock when phone leaves",
                    isOn: Binding(get: { proximity.enabled }, set: { proximity.enabled = $0 }),
                )
                if proximity.enabled {
                    RowDivider()
                    InfoRow(icon: "dot.radiowaves.left.and.right", title: "Phone", value: proximity.statusText)
                    RowDivider()
                    PickerRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Sensitivity",
                        selection: Binding(get: { proximity.sensitivity }, set: { proximity.sensitivity = $0 }),
                        options: ProximityMonitor.Sensitivity.allCases,
                        label: { $0.label },
                    )
                    RowDivider()
                    PickerRow(
                        icon: "clock",
                        title: "Lock after",
                        selection: Binding(get: { proximity.graceSeconds }, set: { proximity.graceSeconds = $0 }),
                        options: ProximityMonitor.graceOptions,
                        label: { "\($0)s" },
                    )
                }
            }
        }
    }

    // MARK: - General

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("GENERAL")
            Card {
                ButtonRow(icon: "qrcode", title: "Pairing QR…", showsChevron: true, action: onShowPairing)
                RowDivider()
                ButtonRow(icon: "server.rack", title: "Server Settings…", showsChevron: true, action: onShowServerSettings)
                RowDivider()
                ButtonRow(
                    icon: client.isActive ? "bolt.horizontal.fill" : "bolt.horizontal",
                    title: client.isActive ? "Disconnect" : "Connect",
                    action: { client.toggle() }
                )
                RowDivider()
                ToggleRow(
                    icon: "power",
                    title: "Start at login",
                    isOn: Binding(get: { LoginItem.isEnabled }, set: { try? LoginItem.setEnabled($0) })
                )
                RowDivider()
                ButtonRow(icon: "arrow.triangle.2.circlepath", title: "Check for Updates…", action: onCheckForUpdates)
                RowDivider()
                ButtonRow(icon: "info.circle", title: "About…", showsChevron: true, action: onShowAbout)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button(role: .destructive, action: confirmUnpair) {
                Text("Unpair…").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .tint(.red)
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

    /// Confirm before discarding the room/key; the phone must rescan a fresh QR after.
    private func confirmUnpair() {
        let alert = NSAlert()
        alert.messageText = "Unpair this Mac?"
        alert.informativeText =
            "The current room and key will be deleted and a new pairing will be generated. "
            + "The phone disconnects and must scan the new QR to pair again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            client.unpair()
            proximity.reloadPairing() // room rotated → the beacon UUID follows it
        }
    }
}
