import SwiftUI
import AppKit
import Sparkle

@main
struct LinkToMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu-bar item is an `NSStatusItem` owned by the AppDelegate (`StatusItemController`),
        // NOT a `MenuBarExtra`: it has to accept dragged files so a file can be sent to the phone
        // with the dashboard closed, and MenuBarExtra exposes no hook to register dragged types on.
        // So the only scene SwiftUI sees is Settings. The Settings window (⌘,) is a real `Settings` scene: native toolbar tabs, standard
        // menu item, remembered position. It reads the objects the AppDelegate owns.
        Settings {
            SettingsRoot(
                client: delegate.client,
                proximity: delegate.proximity,
                appearance: delegate.appearance,
                onApplyLan: { delegate.applyLanSettings() },
                onCheckForUpdates: { delegate.checkForUpdates() }
            )
        }
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
    /// The menu-bar item + its panel. Owns the `NSStatusItem`, so it can be a drop target.
    private lazy var statusItem = StatusItemController(
        client: client,
        proximity: proximity,
        appearance: appearance,
        onOpenWindow: { [weak self] in self?.showDashboardWindow() },
        onOpenSettings: { openSettingsWindow() }
    )
    /// The main dashboard window. Built lazily and reused (the app is now a regular Dock app, so
    /// the window is the primary surface; the menu-bar extra is the quick-glance companion).
    private var dashboardWindow: NSWindow?
    /// The dashboard's navigation state (selected page).
    private let dashboardNav = DashboardNav()
    /// The "Pair your phone" window (first launch, after an unpair, and Settings ▸ Show QR Code…).
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.connect()
        // A local copy fans out to whichever LAN server is live (re-read at call time).
        client.onLocalClip = { [weak self] text in self?.lan?.sendClip(text) }
        // Battery + proximity telemetry fans out to the LAN server too, mirroring clips.
        client.onLocalStat = { [weak self] payload in self?.lan?.sendStat(payload) }
        // An image copy (assembled `file` plaintext) fans out to the LAN server too.
        client.onLocalFile = { [weak self] payload in self?.lan?.sendFile(payload) }
        // An SMS reply request fans out to the LAN server too, mirroring stat/file.
        client.onLocalSms = { [weak self] payload in self?.lan?.sendSms(payload) }
        // Forward the BLE proximity this Mac measures to the phone (over whichever transport is up),
        // so the phone can show the Mac's distance — it can't measure that itself, it only advertises.
        proximity.onReading = { [weak self] reading in self?.client.updateProximity(reading) }
        // Re-advertise under the fresh pairing id (and drop stale auth) when the user re-pairs.
        client.onPairingChanged = { [weak self] in
            self?.applyLanSettings()
            // A rotated pairing is a phone with nothing to scan: show the code straight away.
            self?.showPairingWindow()
        }
        PairingOpener.shared.open = { [weak self] in self?.showPairingWindow() }
        watchLinkForPairing()
        applyLanSettings()
        appearance.applyDockPolicy(reactivate: false) // honour the persisted "Show in Dock" pref at launch
        statusItem.start()           // and the persisted "Show in Menu Bar" pref
        // Don't steal focus here: at launch (esp. as a background "Start at login" item) the
        // user may already be mid-task in another app — order the window front without activating.
        if PairingStore.createdThisLaunch {
            // A fresh install has nothing to show yet: start with the pairing screen.
            showPairingWindow()
        } else {
            showDashboardWindow(activate: false)
        }
        // Prompt for notification permission up front so the first mirrored notification can
        // already raise a banner (the prompt is async; an early request avoids the first one
        // being silently skipped while authorization is still undetermined).
        MacNotifier.requestAuthorizationIfNeeded()
    }

    /// Keep the app alive when the dashboard window is closed — it still lives in the menu bar.
    /// Quit only via the menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Handle `linktomac://send?path=…` — the Finder Share extension handing over a file it can't
    /// send itself (it's sandboxed; this app is not, so the path is readable as-is).
    ///
    /// The path arrives from our own extension, but it is still just a string from outside the
    /// process, so it is checked for being a real file before anything is read.
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls where url.scheme == "linktomac" && url.host == "send" {
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
                  !path.isEmpty
            else { continue }
            let file = URL(fileURLWithPath: path)
            // Files and folders both go; anything that isn't on disk doesn't.
            guard FileManager.default.fileExists(atPath: file.path) else {
                NSLog("[LinkToMac] share extension handed over a path that doesn't exist")
                continue
            }
            files.append(file)
        }
        // One call for all of them, so several arrivals are one batch with one summary.
        client.sendFilesToPhone(files)
    }

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
        server.onRemoteFile = { payload in Task { @MainActor in client.receiveRemoteFile(payload) } }
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
                nav: dashboardNav
            )
            let hosting = NSHostingController(rootView: root)
            // The window is resizable; stop the hosting controller from imposing its own
            // content-derived size constraints on top of ours.
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Link to Mac"
            // Chromeless titlebar: transparent + no title text + full-size content, so the page
            // runs to the top edge and the floating sidebar sits under the traffic lights.
            // Resizable, with the usual zoom button; no full screen. Appearance follows the system.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.insert(.fullScreenNone)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.contentMinSize = NSSize(width: 900, height: 600)
            // Remember the user's size and position; centre only the very first time.
            if !window.setFrameUsingName("LinkToMacDashboard") { window.center() }
            window.setFrameAutosaveName("LinkToMacDashboard")
            // The design puts the traffic lights inside the sidebar card, 22 / 24 pt from its corner.
            WindowChrome.keepTrafficLights(in: window, left: 21, top: 23)
            dashboardWindow = window
        }
        // Explicit user requests (Dock reopen, the menu panel's "Open Window…") still activate —
        // only the just-launched case opts out (see the call in applicationDidFinishLaunching).
        if activate { WindowChrome.bringToFront(dashboardWindow) } else { dashboardWindow?.orderFront(nil) }
    }

    // MARK: - Pairing window

    /// Front the "Pair your phone" window, building it on first use.
    func showPairingWindow() {
        if pairingWindow == nil {
            let root = PairingScreen(client: client) { [weak self] in
                self?.pairingWindow?.orderOut(nil)
                self?.showDashboardWindow()
            }
            // An NSHostingView as the content view (not a hosting controller): with content under
            // the titlebar the frame is then exactly the design's 760 × 500, with no titlebar extra.
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.contentView = hosting
            window.title = "Pair your phone"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // Pin the *frame* to the design's 760 × 500 (min == max, like the dashboard used to be):
            // `contentRect` excludes the titlebar, so without this AppKit adds 32 pt of blank.
            let size = NSSize(width: 760, height: 500)
            window.minSize = size
            window.maxSize = size
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            window.center()
            WindowChrome.keepTrafficLights(in: window, left: 17, top: 13) // the design's pairing window
            pairingWindow = window
        }
        WindowChrome.bringToFront(pairingWindow)
    }

    /// "Pairing finishes on its own": when the phone connects while the pairing window is up, close
    /// it and carry on to the dashboard. Re-arms itself — `withObservationTracking` fires once.
    private func watchLinkForPairing() {
        withObservationTracking {
            _ = client.isLinked
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.client.isLinked, self.pairingWindow?.isVisible == true {
                    self.pairingWindow?.orderOut(nil)
                    self.showDashboardWindow()
                }
                self.watchLinkForPairing()
            }
        }
    }

    /// User-initiated Sparkle update check (shows Sparkle's standard progress/alerts UI).
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
