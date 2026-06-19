import SwiftUI
import AppKit
import Sparkle

@main
struct LinkToMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Window-style menu bar extra: the dropdown is a soft native popover panel, which
        // (unlike a .menu) can host real switches and a designed layout. See `MenuPanel`.
        MenuBarExtra {
            MenuPanel(
                client: delegate.client,
                proximity: delegate.proximity,
                onShowPairing: delegate.showPairingWindow,
                onShowServerSettings: delegate.showServerSettingsWindow,
                onShowAbout: delegate.showAboutWindow,
                onCheckForUpdates: delegate.checkForUpdates,
            )
        } label: {
            // The app mark as a template image (monochrome; the system tints it for the menu bar).
            // Dimmed when the phone isn't linked, so it doubles as an at-a-glance status cue.
            Image("MenuBarIcon")
                .opacity(delegate.client.isLinked ? 1 : 0.45)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the relay client and connects on launch so the agent links up automatically.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = RelayClient()
    /// BLE presence watcher; self-gates on its persisted `enabled`, so this is cheap when off.
    let proximity = ProximityMonitor()
    /// Sparkle updater. `startingUpdater: true` schedules background checks (SUEnableAutomaticChecks);
    /// the feed + EdDSA public key come from Info.plist. No Apple Developer account required.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil,
    )
    /// LAN-direct WebSocket server (relay-less). Listens + advertises over Bonjour so a phone on
    /// the same network connects straight to us; rebuilt by `applyLanSettings()` when the port or
    /// the enabled toggle changes. Reads the pairing fresh on each handshake.
    private var lan: LanServer?
    private var pairingWindow: NSWindow?
    private var serverSettingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.connect()
        // A local copy fans out to whichever LAN server is live (re-read at call time).
        client.onLocalClip = { [weak self] text in self?.lan?.sendClip(text) }
        // Battery telemetry fans out to the LAN server too, mirroring clips.
        client.onLocalStat = { [weak self] payload in self?.lan?.sendStat(payload) }
        // Re-advertise under the fresh pairing id (and drop stale auth) when the user re-pairs.
        client.onPairingChanged = { [weak self] in self?.applyLanSettings() }
        applyLanSettings()
    }

    /// (Re)build the LAN-direct server from the current Server Settings. Inbound clips/commands are
    /// bridged into the relay client's single pasteboard + command path so they're echo-suppressed.
    func applyLanSettings() {
        lan?.stop()
        lan = nil
        client.lanPeerConnected = false // rebuilding: no LAN peer until one re-authenticates
        let s = ServerSettingsStore.load()
        guard s.lanEnabled, let port = UInt16(exactly: s.lanPort) else { return }
        let server = LanServer(port: port, pairingProvider: { PairingStore.load() })
        let client = self.client
        server.onRemoteClip = { text in Task { @MainActor in client.writeRemoteClip(text) } }
        server.onRemoteCommand = { action in Task { @MainActor in client.runRemoteCommand(action) } }
        // `weak server` so the callback doesn't retain the server it's installed on. On connect,
        // push the current battery immediately so the phone shows it without waiting for the poll.
        server.onPeerChange = { [weak server] connected in
            Task { @MainActor in
                client.lanPeerConnected = connected
                if connected, let payload = client.currentBatteryPayload() { server?.sendStat(payload) }
            }
        }
        lan = server
        server.start()
    }

    /// Lazily build and front a window showing the pairing QR (agent app has no Dock icon,
    /// so we must explicitly activate to bring the window forward).
    func showPairingWindow() {
        if pairingWindow == nil {
            let hosting = NSHostingController(rootView: PairingView(client: client))
            let window = NSWindow(contentViewController: hosting)
            window.title = "LinkToMac — Pairing"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 320, height: 420))
            window.center()
            pairingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        pairingWindow?.makeKeyAndOrderFront(nil)
    }

    /// Lazily build and front the runtime relay configuration window (host/port/TLS/password).
    func showServerSettingsWindow() {
        if serverSettingsWindow == nil {
            let hosting = NSHostingController(
                rootView: ServerSettingsView(client: client) { [weak self] in
                    self?.applyLanSettings() // LAN port/enabled may have changed
                    self?.serverSettingsWindow?.close()
                }
            )
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "LinkToMac — Server Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            serverSettingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        serverSettingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Lazily build and front the About window (version + developer/contact links).
    func showAboutWindow() {
        if aboutWindow == nil {
            let hosting = NSHostingController(
                rootView: AboutView(onCheckForUpdates: { [weak self] in self?.checkForUpdates() })
            )
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "About LinkToMac"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    /// User-initiated Sparkle update check (shows Sparkle's standard progress/alerts UI).
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
