import SwiftUI
import AppKit

/// UserDefaults keys for the Mac appearance prefs. Plain (non-isolated) so the `MenuBarExtra`'s
/// `@AppStorage` in `LinkToMacApp` can share the exact key the store writes.
enum AppearanceKeys {
    static let dock = "showInDock"
    static let menuBar = "showInMenuBar"
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

    /// Menu-bar item. The `MenuBarExtra` reads the same UserDefaults key via `@AppStorage`, so the
    /// item inserts/removes reactively when this flips.
    var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: AppearanceKeys.menuBar)
            if !showInMenuBar && !showInDock { showInDock = true } // never hide both surfaces
        }
    }

    init() {
        let d = UserDefaults.standard
        // Default both visible — the historical behaviour (regular Dock app + menu-bar extra).
        showInDock = d.object(forKey: AppearanceKeys.dock) as? Bool ?? true
        showInMenuBar = d.object(forKey: AppearanceKeys.menuBar) as? Bool ?? true
    }

    /// Apply the Dock-icon preference: `.regular` shows it, `.accessory` hides it (menu-bar-only).
    /// Must be called once at launch too — property observers don't fire from `init`. Re-activates
    /// so the open window keeps focus across the policy switch.
    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)
    }
}
