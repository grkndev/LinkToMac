import SwiftUI
import AppKit
import Sparkle

@main
struct LinkToMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Drives `MenuBarExtra` insertion. Shares the exact UserDefaults key `AppearanceStore` writes,
    /// so toggling "Show in Menu Bar" in Settings inserts/removes the item reactively.
    @AppStorage(AppearanceKeys.menuBar) private var showInMenuBar = true

    var body: some Scene {
        // Window-style menu bar extra: the dropdown is a soft native popover panel, which
        // (unlike a .menu) can host real switches and a designed layout. See `MenuPanel`.
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuPanel(
                client: delegate.client,
                onOpenWindow: { delegate.showDashboardWindow() },
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
    /// Dock-icon / menu-bar visibility prefs (Settings → APPEARANCE). Owns the activation policy.
    let appearance = AppearanceStore()
    /// Sparkle updater. `startingUpdater: true` schedules background checks (SUEnableAutomaticChecks);
    /// the feed + EdDSA public key come from Info.plist. No Apple Developer account required.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil,
    )
    /// LAN-direct WebSocket server (relay-less). Listens + advertises over Bonjour so a phone on
    /// the same network connects straight to us; rebuilt by `applyLanSettings()` when the port or
    /// the enabled toggle changes. Reads the pairing fresh on each handshake.
    private var lan: LanServer?
    /// The main dashboard window. Built lazily and reused (the app is now a regular Dock app, so
    /// the window is the primary surface; the menu-bar extra is the quick-glance companion).
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.connect()
        // A local copy fans out to whichever LAN server is live (re-read at call time).
        client.onLocalClip = { [weak self] text in self?.lan?.sendClip(text) }
        // Battery + proximity telemetry fans out to the LAN server too, mirroring clips.
        client.onLocalStat = { [weak self] payload in self?.lan?.sendStat(payload) }
        // An image copy (assembled `file` plaintext) fans out to the LAN server too.
        client.onLocalFile = { [weak self] payload in self?.lan?.sendFile(payload) }
        // Forward the BLE proximity this Mac measures to the phone (over whichever transport is up),
        // so the phone can show the Mac's distance — it can't measure that itself, it only advertises.
        proximity.onReading = { [weak self] reading in self?.client.updateProximity(reading) }
        // Re-advertise under the fresh pairing id (and drop stale auth) when the user re-pairs.
        client.onPairingChanged = { [weak self] in self?.applyLanSettings() }
        applyLanSettings()
        appearance.applyDockPolicy() // honour the persisted "Show in Dock" pref at launch
        // Don't steal focus here: at launch (esp. as a background "Start at login" item) the
        // user may already be mid-task in another app — order the window front without activating.
        showDashboardWindow(activate: false)
        // Prompt for notification permission up front so the first mirrored notification can
        // already raise a banner (the prompt is async; an early request avoids the first one
        // being silently skipped while authorization is still undetermined).
        MacNotifier.requestAuthorizationIfNeeded()
    }

    /// Keep the app alive when the dashboard window is closed — it still lives in the menu bar.
    /// Quit only via the menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon (with the window closed) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return true
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
        server.onRemoteStat = { json in Task { @MainActor in client.writeRemoteStat(json) } }
        server.onRemoteNote = { json in Task { @MainActor in client.writeRemoteNote(json) } }
        server.onRemoteSms = { json in Task { @MainActor in client.writeRemoteSms(json) } }
        server.onRemoteFile = { payload in Task { @MainActor in client.writeRemoteImage(payload) } }
        // `weak server` so the callback doesn't retain the server it's installed on. On connect,
        // push the current battery immediately so the phone shows it without waiting for the poll.
        server.onPeerChange = { [weak server] connected in
            Task { @MainActor in
                client.lanPeerConnected = connected
                if connected, let payload = client.currentStatPayload() { server?.sendStat(payload) }
            }
        }
        lan = server
        server.start()
    }

    /// Lazily build and front the main dashboard window. Hosts `DashboardView` (which folds the
    /// former pairing / server-settings / about windows into its `NavigationStack`). Forced to a
    /// dark appearance so the titlebar matches the dark dashboard content.
    func showDashboardWindow(activate: Bool = true) {
        if dashboardWindow == nil {
            let root = DashboardView(
                client: client,
                proximity: proximity,
                appearance: appearance,
                onApplyLan: { [weak self] in self?.applyLanSettings() }, // LAN port/enabled may have changed
                onCheckForUpdates: { [weak self] in self?.checkForUpdates() }
            )
            let hosting = NSHostingController(rootView: root)
            // We pin the window size ourselves (below); stop the hosting controller from imposing
            // its own content-derived size constraints.
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Link to Mac"
            // Chromeless titlebar: transparent + no title text + full-size content, so the dark
            // dashboard bleeds to the top edge under the floating traffic lights — no visible bar,
            // just the Close/Minimize buttons. No resize, no full screen, no zoom.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false // green button disabled
            window.isReleasedWhenClosed = false
            // 1280×760 matches the reference design 1:1 (left column 466 + 17 gap + 732 right panel +
            // 32/33 side margins). Locked: min == max so the window is a fixed size and can't resize.
            let fixedSize = NSSize(width: 1280, height: 760)
            window.setContentSize(fixedSize)
            window.minSize = fixedSize
            window.maxSize = fixedSize
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            dashboardWindow = window
        }
        // Explicit user requests (Dock reopen, the menu panel's "Open Window…") still activate —
        // only the just-launched case opts out (see the call in applicationDidFinishLaunching).
        if activate { NSApp.activate(ignoringOtherApps: true) }
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    /// User-initiated Sparkle update check (shows Sparkle's standard progress/alerts UI).
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
