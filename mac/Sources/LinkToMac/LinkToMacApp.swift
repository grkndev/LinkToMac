import SwiftUI
import AppKit

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
            )
        } label: {
            Image(systemName: delegate.client.menuBarSymbol)
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
    private var pairingWindow: NSWindow?
    private var serverSettingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.connect()
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
}
