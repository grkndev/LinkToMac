import SwiftUI
import AppKit

@main
struct LinkToMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: delegate.client, onShowPairing: delegate.showPairingWindow)
        } label: {
            Image(systemName: delegate.client.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the relay client and connects on launch so the agent links up automatically.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = RelayClient()
    private var pairingWindow: NSWindow?

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
}
