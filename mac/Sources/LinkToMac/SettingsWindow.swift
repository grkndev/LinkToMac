import SwiftUI
import AppKit

/// The Settings window (⌘,): a native `Settings` scene with five tabs — General, Clipboard,
/// Notifications, Security, Connection. The tab strip is the system's; everything under it is drawn
/// with the design's own form controls (`DSSection`, `DSRow`, `DSSwitch`, …). It replaces the old
/// in-window Settings / Relay screens; the dashboard keeps only content.
struct SettingsRoot: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let appearance: AppearanceStore
    let onApplyLan: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(client: client, appearance: appearance, onCheckForUpdates: onCheckForUpdates)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ClipboardSettingsTab(client: client)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            NotificationSettingsTab(client: client)
                .tabItem { Label("Notifications", systemImage: "bell") }
            MediaSettingsTab(appearance: appearance)
                .tabItem { Label("Media", systemImage: "music.note") }
            SecuritySettingsTab(client: client, proximity: proximity)
                .tabItem { Label("Security", systemImage: "lock") }
            ConnectionSettingsTab(client: client, onApplyLan: onApplyLan)
                .tabItem { Label("Connection", systemImage: "link") }
        }
        .tint(M3.primary)
        .frame(width: 640)
    }
}

/// Holds SwiftUI's `openSettings` action so AppKit code (the menu panel) can call it. The action
/// only exists inside a SwiftUI view, so the dashboard's root view hands it over when it appears.
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()
    var open: (() -> Void)?
}

/// Opens the Settings window from anywhere (menu panel, dashboard).
///
/// Prefers SwiftUI's own `openSettings`; if that has not been handed over yet it presses the app
/// menu's "Settings…" item, which is what the user would do. (Sending the private
/// `showSettingsWindow:` selector does nothing on current macOS.)
@MainActor
func openSettingsWindow() {
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    NSApp.activate(ignoringOtherApps: true)
    if let open = SettingsOpener.shared.open {
        open()
        // The window is created by `openSettings`; make sure it lands on top of the frontmost app.
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.title == "Settings" }?
                .orderFrontRegardless()
        }
        return
    }
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
          let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," })
    else { return }
    appMenu.performActionForItem(at: index)
}

// MARK: - Page chrome

/// Every tab's content: the design's 28 pt side margins, sections 20 pt apart.
private struct SettingsPage<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
        }
        .frame(height: height)
        .background(M3.surface)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let client: RelayClient
    let appearance: AppearanceStore
    let onCheckForUpdates: () -> Void

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var showAbout = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        SettingsPage(height: 480) {
            DSSection(title: "Appearance") {
                DSRow(label: "Show in Dock", divider: false) {
                    DSSwitch(isOn: Binding(get: { appearance.showInDock }, set: { appearance.showInDock = $0 }))
                }
                DSRow(label: "Show in menu bar", note: "At least one stays on, so Link to Mac is always reachable.") {
                    DSSwitch(isOn: Binding(get: { appearance.showInMenuBar }, set: { appearance.showInMenuBar = $0 }))
                }
            }
            DSSection(title: "Startup") {
                DSRow(label: "Open at login", note: "Starts in the menu bar without taking focus.", divider: false) {
                    DSSwitch(isOn: $openAtLogin)
                }
            }
            DSSection(title: "Files") {
                DSRow(label: "Save received files to", divider: false) {
                    DSSmallButton(title: client.fileDrop.folder.lastPathComponent) { _ = client.fileDrop.chooseFolder() }
                }
            }
            DSSection(title: "Updates") {
                DSRow(label: version, note: "Updates are delivered with Sparkle.", divider: false) {
                    DSSmallButton(title: "Check for Updates…", action: onCheckForUpdates)
                }
                Button { showAbout = true } label: {
                    DSRow(label: "About Link to Mac") {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(M3.outline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: openAtLogin) { _, on in
            do { try LoginItem.setEnabled(on) } catch { openAtLogin = LoginItem.isEnabled }
        }
        .sheet(isPresented: $showAbout) {
            VStack(spacing: 0) {
                AboutView(onCheckForUpdates: onCheckForUpdates)
                Button("Done") { showAbout = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
            .frame(width: 520, height: 600)
        }
    }
}

// MARK: - Clipboard

private struct ClipboardSettingsTab: View {
    let client: RelayClient

    var body: some View {
        SettingsPage(height: 260) {
            DSSection(title: "Sync with your phone") {
                DSRow(label: "Send copies to Android", note: "Mirror this Mac's clipboard to the phone.", divider: false) {
                    DSSwitch(isOn: Binding(get: { client.sendToAndroid }, set: { client.sendToAndroid = $0 }))
                }
                DSRow(label: "Sync images", note: "Send copied images to the phone's clipboard.") {
                    DSSwitch(isOn: Binding(get: { client.syncImages }, set: { client.syncImages = $0 }))
                }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    let client: RelayClient
    /// True once the OS reports notification permission as denied. Re-checked whenever the app
    /// regains focus, since the user typically flips it in System Settings and switches back.
    @State private var denied = false

    var body: some View {
        SettingsPage(height: denied ? 280 : 220) {
            DSSection(title: "Banners") {
                DSRow(label: "Notification banners",
                      note: denied ? "Blocked in System Settings — banners can't show until you allow them."
                                   : "Show a macOS banner when your phone gets a notification.",
                      noteColor: denied ? M3.error : M3.onSurfaceVariant, divider: false) {
                    DSSwitch(isOn: Binding(get: { client.showNotificationBanners },
                                           set: { client.showNotificationBanners = $0 }))
                }
                if denied {
                    DSRow(label: "Open Notification Settings…") {
                        DSSmallButton(title: "Open") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                    }
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async { denied = await MacNotifier.currentStatus() == .denied }
}

// MARK: - Media

/// Settings ▸ Media. What the design also has here — media keys / Control Center, a volume-source
/// popup, artwork quality and hidden players — needs the Mac to publish Now Playing to macOS or the
/// phone to send more, and isn't built yet.
private struct MediaSettingsTab: View {
    let appearance: AppearanceStore

    var body: some View {
        SettingsPage(height: 260) {
            DSSection(title: "Media controls") {
                DSRow(label: "Show what's playing on my phone",
                      note: "Adds Now Playing to the sidebar, the Overview and the menu bar panel.", divider: false) {
                    DSSwitch(isOn: Binding(get: { appearance.showMedia }, set: { appearance.showMedia = $0 }))
                }
            }
            DSSection(title: "Menu bar") {
                DSRow(label: "Show song title next to the icon",
                      note: "Only while something is playing.", divider: false) {
                    DSSwitch(isOn: Binding(get: { appearance.showMediaTitleInMenuBar },
                                           set: { appearance.showMediaTitleInMenuBar = $0 }))
                }
                .opacity(appearance.showMedia ? 1 : 0.45)
                .allowsHitTesting(appearance.showMedia)
            }
        }
    }
}

// MARK: - Security

private struct SecuritySettingsTab: View {
    let client: RelayClient
    let proximity: ProximityMonitor

    var body: some View {
        SettingsPage(height: proximity.enabled ? 510 : 410) {
            DSSection(title: "Auto-lock",
                      footnote: "Uses Bluetooth signal strength from your phone. Turn on Auto-lock on the phone too.") {
                DSRow(label: "Lock this Mac when my phone leaves",
                      note: proximity.enabled ? proximity.statusText : nil, divider: false) {
                    DSSwitch(isOn: Binding(get: { proximity.enabled }, set: { proximity.enabled = $0 }))
                }
                if proximity.enabled {
                    DSRow(label: "Sensitivity") {
                        DSSegmented(selection: Binding(get: { proximity.sensitivity }, set: { proximity.sensitivity = $0 }),
                                    options: Array(ProximityMonitor.Sensitivity.allCases), label: { $0.label })
                    }
                    DSRow(label: "Lock after") {
                        DSPopup(selection: Binding(get: { proximity.graceSeconds }, set: { proximity.graceSeconds = $0 }),
                                options: ProximityMonitor.graceOptions, label: { "\($0) seconds" })
                    }
                }
            }
            DSSection(title: "Pairing") {
                DSRow(label: "Paired phone", divider: false) {
                    Text(client.phoneName ?? "Android").font(.system(size: 13)).foregroundStyle(M3.onSurfaceVariant)
                }
                DSRow(label: "Pair a different phone") {
                    DSSmallButton(title: "Show QR Code…") { PairingOpener.shared.open?() }
                }
                DSRow(label: "Unpair this Mac", note: "Removes the keys from this Mac. The phone has to scan a new code.",
                      labelColor: M3.error) {
                    DSSmallButton(title: "Unpair…", style: .destructive, action: confirmUnpair)
                }
            }
        }
    }

    /// Confirm before discarding the room/key; the phone must rescan a fresh QR afterwards.
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

// MARK: - Connection

/// Link status plus the relay endpoint and LAN-direct form. Edits are a draft: nothing applies
/// until **Save**, which persists, reconnects the relay and rebuilds the LAN server.
private struct ConnectionSettingsTab: View {
    let client: RelayClient
    let onApplyLan: () -> Void

    @State private var host = ""
    @State private var port = ""
    @State private var secure = true
    @State private var token = ""
    @State private var lanEnabled = true
    @State private var lanPort = ""
    @State private var loaded = false

    private var portValue: Int? { Self.port(port) }
    private var lanPortValue: Int? { Self.port(lanPort) }
    private var hasRelay: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
    /// At least one transport must be valid: a relay endpoint, or LAN-direct.
    private var canSave: Bool { (hasRelay && portValue != nil) || (lanEnabled && lanPortValue != nil) }

    private static func port(_ text: String) -> Int? {
        guard let p = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }

    private var statusDetail: String {
        if client.lanPeerConnected { return "Connected over LAN · relay is the fallback when you are away" }
        if client.peerOnline { return "Connected through the relay" }
        return client.isActive ? "Waiting for your phone" : "The relay link is paused"
    }

    var body: some View {
        SettingsPage(height: 620) {
            DSSection(title: "Status") {
                DSRow(label: client.isActive ? "Relay link active" : "Relay link paused",
                      note: statusDetail, dot: client.isActive ? M3.success : M3.outline, divider: false) {
                    DSSmallButton(title: client.isActive ? "Disconnect" : "Connect") { client.toggle() }
                }
            }
            DSSection(title: "Relay server",
                      footnote: "These values travel inside the pairing QR, so the phone sets itself up when it scans.") {
                DSRow(label: "Server address", divider: false) { DSField(text: $host, prompt: "relay.example.com") }
                DSRow(label: "Port") { DSField(text: $port, prompt: "443", width: 80, invalid: hasRelay && portValue == nil) }
                DSRow(label: "Use TLS (wss://)", note: secure ? "Encrypted, needs a certificate" : "Plaintext — LAN only") {
                    DSSwitch(isOn: $secure)
                }
                DSRow(label: "Password") { DSField(text: $token, prompt: "Relay password", secure: true) }
            }
            DSSection(title: "LAN-direct") {
                DSRow(label: "Connect directly on the same Wi-Fi", divider: false) { DSSwitch(isOn: $lanEnabled) }
                if lanEnabled {
                    DSRow(label: "LAN port") { DSField(text: $lanPort, prompt: "53124", width: 80, invalid: lanPortValue == nil) }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                DSSmallButton(title: "Revert", action: load)
                DSSmallButton(title: "Save", style: .primary, enabled: canSave, action: save)
            }
        }
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        let s = ServerSettingsStore.load()
        host = s.host
        port = String(s.port)
        secure = s.secure
        token = s.token
        lanEnabled = s.lanEnabled
        lanPort = String(s.lanPort)
        loaded = true
    }

    private func save() {
        ServerSettingsStore.save(ServerSettings(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue ?? 443,
            secure: secure,
            token: token.trimmingCharacters(in: .whitespaces),
            lanEnabled: lanEnabled,
            lanPort: lanPortValue ?? ServerSettingsStore.defaultLanPort
        ))
        // Apply immediately: reconnect the relay if already active, otherwise start it; then
        // rebuild the LAN server (port/enabled may have changed).
        if client.isActive { client.reconnect() } else { client.connect() }
        onApplyLan()
    }
}
