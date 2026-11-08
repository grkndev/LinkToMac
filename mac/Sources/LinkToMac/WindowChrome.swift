import AppKit

/// Window helpers for the chromeless look: content under a transparent titlebar, with the traffic
/// lights moved to where the design draws them (inside the sidebar card, not on its edge).
@MainActor
enum WindowChrome {
    /// Put the close / minimise / zoom buttons `left`/`top` points from the window's top-left corner.
    ///
    /// AppKit lays the buttons out in a titlebar strip of its own height, so moving them lower
    /// first grows that strip (else they'd be clipped), and AppKit resets all of it on every
    /// resize — hence `keepTrafficLights`, which re-applies it whenever the window changes.
    static func placeTrafficLights(in window: NSWindow, left: CGFloat, top: CGFloat, pitch: CGFloat = 20) {
        guard let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let needed = top + close.frame.height + 6
        if container.frame.height < needed {
            container.setFrameSize(NSSize(width: container.frame.width, height: needed))
            container.setFrameOrigin(NSPoint(x: container.frame.minX, y: (container.superview?.bounds.height ?? window.frame.height) - needed))
            titlebar.setFrameSize(NSSize(width: titlebar.frame.width, height: needed))
            titlebar.setFrameOrigin(.zero)
        }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: left + CGFloat(i) * pitch, y: titlebar.bounds.height - top - button.frame.height))
        }
    }

    /// Re-apply `placeTrafficLights` whenever AppKit would have reset it.
    static func keepTrafficLights(in window: NSWindow, left: CGFloat, top: CGFloat) {
        placeTrafficLights(in: window, left: left, top: top)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didExitFullScreenNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window { placeTrafficLights(in: window, left: left, top: top) }
                }
            }
        }
    }

    /// Guards `bringToFront` against the reopen event it can cause (see below).
    private static var reopening = false

    /// Bring a window in front of everything, for an explicit user request ("Open", the Dock icon).
    ///
    /// `NSApp.activate` is only a *request*: since macOS 14 activation is cooperative, and when the
    /// request comes from a non-activating panel (or while Xcode / a browser is frontmost) the system
    /// may simply decline — the window then ordered front but stayed BEHIND the frontmost app.
    /// Asking Launch Services to open ourselves is honoured as a user action, so if we're still not
    /// active after the direct request, do that: it activates the app and, for a running app, sends
    /// the reopen event that fronts the dashboard.
    static func bringToFront(_ window: NSWindow?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        guard !NSApp.isActive, !reopening else { return }
        reopening = true
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { reopening = false }
        }
    }
}
