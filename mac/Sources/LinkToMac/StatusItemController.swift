import AppKit
import SwiftUI

/// The menu-bar item, built by hand on `NSStatusItem` instead of SwiftUI's `MenuBarExtra`.
///
/// **Why AppKit.** The item has to be a *drag destination*: dragging a file onto the icon opens the
/// panel with its drop zone, so a file can be sent to the phone without the dashboard window ever
/// being open. `MenuBarExtra` exposes no access to the underlying `NSStatusItem`, so there is no
/// hook to register dragged types on. The panel's contents are the SwiftUI `MenuPanel`, shown in
/// our own borderless `NSPanel` (not an `NSPopover`) so it can look exactly like the design: a
/// rounded, translucent card with no arrow.
@MainActor
final class StatusItemController {
    private let client: RelayClient
    private let appearance: AppearanceStore
    private let onOpenWindow: () -> Void

    private let proximity: ProximityMonitor
    private let onOpenSettings: () -> Void

    private var statusItem: NSStatusItem?
    private var panel: MenuPanelWindow?
    /// Y of the panel's top edge, kept while it is open: the content changes height (a drag swaps
    /// the card for the drop zone) and the panel must grow downward, not upward.
    private var anchorTop: CGFloat = 0
    private var hosting: NSHostingView<AnyView>?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    /// When the panel last closed. A click on the icon that *closes* the panel first makes it lose
    /// focus (closing it) and then reaches the button — which must not reopen it.
    private var closedAt = Date.distantPast

    private var isPanelShown: Bool { panel?.isVisible == true }

    init(client: RelayClient, proximity: ProximityMonitor, appearance: AppearanceStore,
         onOpenWindow: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.client = client
        self.proximity = proximity
        self.appearance = appearance
        self.onOpenWindow = onOpenWindow
        self.onOpenSettings = onOpenSettings
    }

    func start() {
        applyVisibility()
        track(\.showInMenuBar) { [weak self] in self?.applyVisibility() }
        track(\.isLinked) { [weak self] in self?.applyLinkState() }
    }

    // MARK: - Item lifecycle

    private func applyVisibility() {
        if appearance.showInMenuBar {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = NSImage(named: "MenuBarIcon")
                image?.isTemplate = true // let the system tint it for light/dark menu bars
                button.image = image
                button.target = self
                button.action = #selector(togglePanel)

                // A transparent overlay is the only way to make the status button a drag
                // destination — `NSStatusBarButton` can't be subclassed into one. Clicks are
                // forwarded so the button still behaves normally.
                let drop = StatusDropView(frame: button.bounds)
                drop.autoresizingMask = [.width, .height]
                drop.onDragEnter = { [weak self] in self?.showPanel(takeKey: false) }
                drop.onDrop = { [weak self] urls in
                    NSLog("[LinkToMac] status item drop: %d item(s)", urls.count)
                    self?.client.sendFilesToPhone(urls)
                }
                button.addSubview(drop)
            }
            statusItem = item
            applyLinkState()
        } else {
            guard let item = statusItem else { return }
            closePanel()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Dim the icon when the phone isn't linked, so it doubles as an at-a-glance status cue
    /// (the behaviour the `MenuBarExtra` label had).
    private func applyLinkState() {
        statusItem?.button?.alphaValue = client.isLinked ? 1 : 0.45
    }

    // MARK: - Panel
    //
    // Hard-won rules (each one was a visible bug):
    //  • Never activate the app to show the panel. Activating a regular app raises ALL its windows —
    //    the dashboard would pop up behind every icon click — and swaps the global menu bar to ours
    //    and back again (the flicker). A non-activating panel can still take key status, so its
    //    buttons and Esc work without any of that.
    //  • `hidesOnDeactivate = false`. NSPanel's default hides it whenever the app is inactive, which
    //    is the normal state here, so the panel would vanish the moment it appeared.
    //  • The size is measured before the first show. A zero-sized first frame was an invisible panel
    //    that only appeared on a later click.
    //  • A click that closes the panel must not reopen it (`closedAt`).

    @objc private func togglePanel() {
        if isPanelShown {
            closePanel()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            showPanel(takeKey: true)
        }
    }

    private func makePanel() -> MenuPanelWindow {
        let root = MenuPanel(
            client: client,
            proximity: proximity,
            onOpenWindow: { [weak self] in self?.closePanel(); self?.onOpenWindow() },
            onOpenSettings: { [weak self] in self?.closePanel(); self?.onOpenSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        .background(MenuPanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(M3.outlineVariant, lineWidth: 0.5))
        // The content's height changes (a drag swaps the card for the drop zone): follow it.
        .background(PanelSizeReader { [weak self] size in self?.resizePanel(to: size) })

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        self.hosting = hosting
        let panel = MenuPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Resize to the content, keeping the top edge (and the horizontal position) where they were.
    private func resizePanel(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.isVisible else { return }
        let frame = NSRect(x: panel.frame.minX, y: anchorTop - size.height, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// `takeKey` is true for a click (so Esc and the buttons work at once) and false for a drag,
    /// which must leave focus with Finder, who owns the drag session: pulling focus away mid-drag
    /// wedges it — the panel opens, the drop zone lights up, and the drop never lands.
    private func showPanel(takeKey: Bool) {
        guard !isPanelShown, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Measure first, so the very first show already has the right size and position.
        hosting?.layoutSubtreeIfNeeded()
        let fit = hosting?.fittingSize ?? .zero
        let size = NSSize(width: fit.width > 0 ? fit.width : 340, height: fit.height > 0 ? fit.height : 280)

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        anchorTop = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: anchorTop - size.height, width: size.width, height: size.height), display: true)

        if takeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        installDismissMonitors(watchFocus: takeKey)
    }

    private func closePanel() {
        guard isPanelShown else { return }
        closedAt = Date()
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    /// Like a menu: Esc, or clicking away, closes it. Three sources, because the app is usually NOT
    /// active when the panel is up (we deliberately never activate it):
    ///  • a global monitor sees clicks in OTHER apps;
    ///  • a local monitor sees clicks in OUR other windows (the dashboard, Settings) — but not on the
    ///    panel itself or on the status item, whose click is the toggle;
    ///  • Esc, which only reaches us while the app is active (or the panel is key).
    private func installDismissMonitors(watchFocus: Bool) {
        removeDismissMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, isPanelShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { closePanel(); return nil } // Esc
            } else if event.window !== panel, event.window !== statusItem?.button?.window {
                closePanel()
            }
            return event
        }
        // The click that activates our app (on the dashboard or Settings while the panel is up) is
        // swallowed for activation and the monitors above never see it — but becoming active IS
        // "clicking away". The panel never activates the app itself, so this can't fire on its own.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        if watchFocus, let panel {
            // Losing key status is also "clicking away" (focus moved to another window or app).
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
        }
    }

    private func removeDismissMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        clickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
        activeObserver = nil
    }

    // MARK: - Observation

    /// Re-run `onChange` whenever the tracked value changes. `withObservationTracking` fires once,
    /// so it re-arms itself each time.
    private func track<T>(_ read: @escaping @MainActor (StatusItemController) -> T,
                          onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = read(self)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                onChange()
                self.track(read, onChange: onChange)
            }
        }
    }

    private func track(_ key: KeyPath<StatusItemController, Bool>,
                       onChange: @escaping @MainActor () -> Void) {
        track({ $0[keyPath: key] }, onChange: onChange)
    }

    private var showInMenuBar: Bool { appearance.showInMenuBar }
    private var isLinked: Bool { client.isLinked }
}

/// Transparent drag destination laid over the status-bar button.
///
/// Entering with a file opens the panel (whose drop zone is the real target); dropping straight on
/// the icon is handled here too, so a quick flick at the menu bar works without waiting for the
/// panel. Clicks are forwarded to the button underneath so normal toggling is unaffected.
private final class StatusDropView: NSView {
    var onDragEnter: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // File URLs (Finder) and file promises (Mail attachments, Photos, Safari downloads).
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    /// Without this AppKit re-asks on every mouse move and a missing implementation can let the
    /// destination lapse mid-drag; dropping straight on the icon then does nothing.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // `fileURLsOnly`: without it a dragged web link or a text clip also reads back as an NSURL.
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        // Real file URLs are authoritative: some sources offer a URL AND a promise for the same
        // file, and acting on both would send it twice.
        if !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        // No file URLs: a Mail attachment, a Photos item or a Safari download, which is only a
        // *promise* to write the file. Ask the source app to write it into a staging folder.
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver]) ?? []
        guard !receivers.isEmpty else { return false }
        receivePromises(receivers)
        return true
    }

    /// Receives each promised file into one staging folder and, once every one has answered (or the
    /// source app has been silent for two minutes), hands the staged URLs over as one drop.
    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        guard let folder = try? DropStaging.makeFolder() else {
            Self.reportUnreadable(receivers.count)
            return
        }
        // A receiver can promise several files; each one reports back separately.
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let collector = PromiseCollector(expected: expected) { [weak self] urls, failed in
            if !urls.isEmpty { self?.onDrop?(urls) }
            if failed > 0 { Self.reportUnreadable(failed) }
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                collector.received(error == nil ? url : nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { collector.finish() }
    }

    private static func reportUnreadable(_ count: Int) {
        let what = count == 1 ? "1 item" : "\(count) items"
        Task { await MacNotifier.post(title: "Couldn't read \(what)", body: "Drop files from Finder instead.") }
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSButton)?.performClick(nil)
    }
}

/// Gathers the answers of several file-promise receivers (they arrive on the main queue, one per
/// promised file) and reports once: when all have answered, or when `finish()` is called because the
/// source app never will. Reports at most once.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var failed = 0
    private var finished = false
    private let done: @MainActor @Sendable ([URL], Int) -> Void

    init(expected: Int, done: @escaping @MainActor @Sendable ([URL], Int) -> Void) {
        remaining = expected
        self.done = done
    }

    /// A promised file arrived (`url`) or couldn't be delivered (`nil`).
    func received(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) } else { failed += 1 }
        remaining -= 1
        let all = remaining <= 0
        lock.unlock()
        if all { finish() }
    }

    /// Reports what has arrived so far, once. Anything still outstanding counts as unreadable.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = (urls, failed + max(0, remaining))
        lock.unlock()
        let done = self.done
        Task { @MainActor in done(result.0, result.1) }
    }
}

/// A borderless panel that can still take key status (for Esc and the buttons).
private final class MenuPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel's translucent card: system blur under a tint of the surface colour.
private struct MenuPanelBackground: View {
    var body: some View {
        ZStack {
            VisualEffect()
            M3.surface.opacity(0.72)
        }
    }

    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

/// Reports the size of the view it is the background of, so the panel can follow its content.
private struct PanelSizeReader: View {
    let onChange: (CGSize) -> Void
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size) }
                .onChange(of: geo.size) { _, size in onChange(size) }
        }
    }
}
