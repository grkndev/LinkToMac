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
        switch client.status {
        case .joined:
            return client.peerOnline
                ? StatusInfo(text: "Connected · Android online", color: .green)
                : StatusInfo(text: "Waiting for Android", color: .orange)
        case .connecting, .connected:
            return StatusInfo(text: "Connecting…", color: .orange)
        case .disconnected:
            return client.isActive
                ? StatusInfo(text: "Connecting…", color: .orange)
                : StatusInfo(text: "Disconnected", color: .gray)
        case .error:
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

// MARK: - Building blocks

/// Small uppercased group title, System-Settings style.
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
    }
}

/// Rounded grouped container holding stacked rows; clips so row hover stays inside corners.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// Hairline separator inset to start after the leading icon column.
private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 38)
    }
}

private struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
    }
}

private struct ToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

/// A row with a leading icon, a title, and a trailing pop-up menu picker.
private struct PickerRow<Value: Hashable>: View {
    let icon: String
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct ButtonRow: View {
    let icon: String
    let title: String
    var showsChevron: Bool = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowIcon(name: icon)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}
