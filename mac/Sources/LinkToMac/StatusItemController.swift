import AppKit
import SwiftUI

/// The menu-bar item, built by hand on `NSStatusItem` instead of SwiftUI's `MenuBarExtra`.
///
/// **Why AppKit.** The item has to be a *drag destination*: dragging a file onto the icon opens the
/// panel with its drop zone, so a file can be sent to the phone without the dashboard window ever
/// being open. `MenuBarExtra` exposes no access to the underlying `NSStatusItem`, so there is no
/// hook to register dragged types on. The panel's contents are still the same SwiftUI `MenuPanel`,
/// now inside an `NSPopover`.
@MainActor
final class StatusItemController {
    private let client: RelayClient
    private let appearance: AppearanceStore
    private let onOpenWindow: () -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    init(client: RelayClient, appearance: AppearanceStore, onOpenWindow: @escaping () -> Void) {
        self.client = client
        self.appearance = appearance
        self.onOpenWindow = onOpenWindow
    }

    func start() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel(
                client: client,
                onOpenWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenWindow()
                }
            )
            // Same affordance as the dashboard window, sized for the panel.
            .phoneFileDrop(client: client, compact: true)
        )
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
                drop.onDragEnter = { [weak self] in self?.showPanel(activate: false) }
                drop.onDrop = { [weak self] url in
                    NSLog("[LinkToMac] status item drop: %@", url.lastPathComponent)
                    self?.client.sendFileToPhone(url)
                }
                button.addSubview(drop)
            }
            statusItem = item
            applyLinkState()
        } else {
            guard let item = statusItem else { return }
            popover.performClose(nil)
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

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel(activate: true) }
    }

    /// `activate` MUST be false when this is called from a drag.
    ///
    /// Finder owns the drag session, and pulling activation away from it mid-drag wedges that
    /// session: the panel opens, the drop zone lights up, and then the drop never lands — the
    /// drag just hangs under the cursor. Activation is only right when the user *clicked* us,
    /// where a transient popover needs the app active to take key status.
    private func showPanel(activate: Bool) {
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { NSApp.activate(ignoringOtherApps: true) }
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
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
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
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let first = urls.first
        else { return false }
        onDrop?(first)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSButton)?.performClick(nil)
    }
}
