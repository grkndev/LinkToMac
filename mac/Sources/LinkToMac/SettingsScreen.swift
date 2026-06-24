import SwiftUI
import AppKit

/// Pushed from the dashboard's Settings tile. The single home for **every** setting — the clipboard /
/// proximity toggles that used to live in the menu-bar panel, the relay endpoint (now its own
/// `RelayScreen`, reached by a row), pairing, connect, login item, updates, about, and the
/// destructive unpair. Built in the M3 dashboard language: a centered column of connected
/// `M3SettingsRow`/`M3ToggleRow`/`M3PickerRow` groups under `M3SectionHeader`s.
struct SettingsScreen: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let appearance: AppearanceStore
    let onCheckForUpdates: () -> Void
    /// Pushes a sub-screen on the dashboard's route stack (relay / about).
    let onOpen: (DashRoute) -> Void

    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                group("CLIPBOARD") {
                    M3ToggleRow(
                        icon: "arrow.up.arrow.down", title: "Send copies to Android",
                        subtitle: "Mirror this Mac's clipboard to the phone",
                        isOn: Binding(get: { client.sendToAndroid }, set: { client.sendToAndroid = $0 })
                    )
                }

                group("SECURITY") {
                    M3ToggleRow(
                        icon: "lock.laptopcomputer", title: "Lock when phone leaves",
                        subtitle: proximity.enabled ? proximity.statusText : "Auto-lock when the phone is out of Bluetooth range",
                        isOn: Binding(get: { proximity.enabled }, set: { proximity.enabled = $0 }),
                        position: proximity.enabled ? .first : .single
                    )
                    if proximity.enabled {
                        M3PickerRow(
                            icon: "antenna.radiowaves.left.and.right", title: "Sensitivity",
                            selection: Binding(get: { proximity.sensitivity }, set: { proximity.sensitivity = $0 }),
                            options: ProximityMonitor.Sensitivity.allCases, label: { $0.label },
                            position: .middle
                        )
                        M3PickerRow(
                            icon: "clock", title: "Lock after",
                            selection: Binding(get: { proximity.graceSeconds }, set: { proximity.graceSeconds = $0 }),
                            options: ProximityMonitor.graceOptions, label: { "\($0)s" },
                            position: .last
                        )
                    }
                }

                group("CONNECTION") {
                    M3SettingsRow(icon: "server.rack", title: "Relay Server",
                                  subtitle: relaySubtitle, position: .first) { onOpen(.relay) }
                    M3SettingsRow(icon: "qrcode", title: "Pairing QR",
                                  subtitle: "Show the code to pair a phone",
                                  position: .middle) { showPairing = true }
                    M3SettingsRow(
                        icon: client.isActive ? "bolt.horizontal.fill" : "bolt.horizontal",
                        title: client.isActive ? "Disconnect" : "Connect",
                        subtitle: client.isActive ? "Relay link is active" : "Relay link is paused",
                        trailingSymbol: nil, position: .last
                    ) { client.toggle() }
                }

                group("APPEARANCE") {
                    M3ToggleRow(
                        icon: "dock.rectangle", title: "Show in Dock",
                        subtitle: "Show the app icon in the Dock",
                        isOn: Binding(get: { appearance.showInDock }, set: { appearance.showInDock = $0 }),
                        position: .first
                    )
                    M3ToggleRow(
                        icon: "menubar.rectangle", title: "Show in Menu Bar",
                        subtitle: "Show the icon in the macOS menu bar",
                        isOn: Binding(get: { appearance.showInMenuBar }, set: { appearance.showInMenuBar = $0 }),
                        position: .last
                    )
                }

                group("GENERAL") {
                    M3ToggleRow(
                        icon: "power", title: "Start at login",
                        subtitle: "Launch LinkToMac when you log in",
                        isOn: Binding(get: { LoginItem.isEnabled }, set: { try? LoginItem.setEnabled($0) }),
                        position: .first
                    )
                    M3SettingsRow(icon: "arrow.triangle.2.circlepath", title: "Check for Updates",
                                  trailingSymbol: nil, position: .middle, action: onCheckForUpdates)
                    M3SettingsRow(icon: "info.circle", title: "About",
                                  position: .last) { onOpen(.about) }
                }

                group("DANGER ZONE") {
                    M3SettingsRow(icon: "link.badge.plus", title: "Unpair…",
                                  subtitle: "Delete this pairing and generate a new one",
                                  trailingSymbol: nil, role: .destructive, action: confirmUnpair)
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M3.surface)
        .sheet(isPresented: $showPairing) {
            VStack(spacing: 0) {
                PairingView(client: client)
                Button("Done") { showPairing = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
        }
    }

    /// A section header + a connected group of the rows it wraps.
    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            M3SectionHeader(title)
            VStack(spacing: 3) { content() }
        }
    }

    /// One-line summary of the relay endpoint for the "Relay Server" row.
    private var relaySubtitle: String {
        let s = ServerSettingsStore.load()
        let host = s.host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? "LAN-direct only — no relay set" : "\(host):\(s.port)"
    }

    /// Confirm before discarding the room/key; the phone must rescan a fresh QR after. Mirrors the
    /// flow that used to live in `MenuPanel`.
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
