import SwiftUI
import AppKit

/// UserDefaults keys for the Mac appearance prefs. Plain (non-isolated) so anything reading them
/// outside this store shares the exact key it writes.
enum AppearanceKeys {
    static let dock = "showInDock"
    static let menuBar = "showInMenuBar"
    static let media = "showMedia"
    static let menuBarTitle = "showMediaTitleInMenuBar"
}

/// Persisted **Mac appearance** preferences: whether the app shows a Dock icon (`.regular` vs
/// `.accessory` activation policy) and a menu-bar item (`MenuBarExtra` insertion). The two surfaces
/// are coordinated so **at least one stays visible** — otherwise the user could hide both and lose
/// every way to reach the app.
@MainActor
@Observable
final class AppearanceStore {
    /// Dock icon. Mirrors the app's activation policy; persisted + applied on change.
    var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: AppearanceKeys.dock)
            if !showInDock && !showInMenuBar { showInMenuBar = true } // never hide both surfaces
            applyDockPolicy()
        }
    }

    /// Menu-bar item. `StatusItemController` tracks this property (`withObservationTracking`) and
    /// adds/removes its `NSStatusItem` when it flips.
    var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: AppearanceKeys.menuBar)
            if !showInMenuBar && !showInDock { showInDock = true } // never hide both surfaces
        }
    }

    /// "Show what's playing on my phone" (Settings ▸ Media): the Now Playing sidebar page, the
    /// Overview's mini player and the menu panel's. Off hides all three; the phone keeps sending.
    var showMedia: Bool {
        didSet { UserDefaults.standard.set(showMedia, forKey: AppearanceKeys.media) }
    }

    /// "Show song title next to the icon": the status item grows to "♪ Title · Artist" while a
    /// track plays or is paused, and shrinks back to the bare icon otherwise. Off by default.
    var showMediaTitleInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMediaTitleInMenuBar, forKey: AppearanceKeys.menuBarTitle) }
    }

    init() {
        let d = UserDefaults.standard
        // Default both visible — the historical behaviour (regular Dock app + menu-bar extra).
        showInDock = d.object(forKey: AppearanceKeys.dock) as? Bool ?? true
        showInMenuBar = d.object(forKey: AppearanceKeys.menuBar) as? Bool ?? true
        showMedia = d.object(forKey: AppearanceKeys.media) as? Bool ?? true
        showMediaTitleInMenuBar = d.object(forKey: AppearanceKeys.menuBarTitle) as? Bool ?? false
    }

    /// Apply the Dock-icon preference: `.regular` shows it, `.accessory` hides it (menu-bar-only).
    /// Must be called once at launch too — property observers don't fire from `init`. Re-activates
    /// so the open window keeps focus across the policy switch.
    func applyDockPolicy(reactivate: Bool = true) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Switching the policy drops activation; take it back so an open window keeps focus. At launch
        // we must NOT: a "Start at login" launch would yank focus from whatever the user is doing.
        if reactivate { NSApp.activate(ignoringOtherApps: true) }
    }
}
