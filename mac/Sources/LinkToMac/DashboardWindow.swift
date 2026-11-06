import SwiftUI

/// Root view of the main dashboard window (hosted by `AppDelegate.showDashboardWindow()`). A
/// two-column layout matching the reference design: `PhonePanel` on the left, `FeaturePanel` on
/// the right. The Clipboard / Settings / About sub-screens (which replaced the three standalone
/// `NSWindow`s) are shown via an **explicit `path` stack (`DashboardNav`) with our own Back
/// button** rather than a `NavigationStack` — a hosted `NSHostingController` window doesn't render
/// the navigation titlebar back button. The button is a titlebar accessory
/// (`makeDashboardBackAccessory`), which is why the stack lives in a shared object.
///
/// Force-dark (`.preferredColorScheme(.dark)`) to match the design; the window also sets a
/// `.darkAqua` appearance so the titlebar follows. **Phase 1: the panels show placeholder
/// telemetry; the Settings sub-tree is fully functional.**
struct DashboardView: View {
    let client: RelayClient
    let proximity: ProximityMonitor
    let appearance: AppearanceStore
    let onApplyLan: () -> Void
    let onCheckForUpdates: () -> Void

    /// Sub-screen stack, shared with the titlebar's Back button (an AppKit accessory outside this
    /// view tree — see `TitlebarBackView`). Empty == the dashboard home.
    let nav: DashboardNav
    private var path: [DashRoute] {
        get { nav.path }
        nonmutating set { nav.path = newValue }
    }

    var body: some View {
        ZStack {
            M3.surface.ignoresSafeArea()
            // `home` stays mounted underneath the sub-screen instead of being swapped out —
            // unmounting it destroyed FeaturePanel's @State (selected tab, open SMS thread,
            // pagination) on every push. Hidden + hit-test-disabled while a route is up.
            home
                .opacity(path.isEmpty ? 1 : 0)
                .allowsHitTesting(path.isEmpty)
            if let route = path.last {
                screen(for: route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(M3.surface)
                    // Same top clearance as `home`. The Back button lives in the titlebar (next to
                    // the traffic lights), not here: drawn from SwiftUI into the titlebar band it
                    // vanished on macOS 27, because that band is painted over the content.
                    .padding(.top, 40)
                    // ⌘[ — the standard "back". A zero-size hidden button, so it works wherever
                    // the titlebar button is or isn't.
                    .background {
                        Button("Back", action: nav.pop)
                            .keyboardShortcut("[", modifiers: .command)
                            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
        }
        // Drag any file onto the window and the whole dashboard becomes the drop target; the same
        // overlay then carries the send percentage. The menu-bar panel gets the compact variant,
        // so the affordance reads the same whether or not this window is open.
        .phoneFileDrop(client: client)
        .preferredColorScheme(.dark)
    }

    // MARK: - Home

    private var home: some View {
        HStack(alignment: .top, spacing: 17) {
            PhonePanel(client: client, proximity: proximity, onOpen: { path.append($0) })
            FeaturePanel(client: client)
        }
        .padding(.leading, 32)
        .padding(.trailing, 33)
        .padding(.top, 40) // clear the floating traffic lights (no titlebar now)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sub-screens

    @ViewBuilder
    private func screen(for route: DashRoute) -> some View {
        switch route {
        case .clipboard:
            ClipHistoryScreen(client: client)
        case .settings:
            SettingsScreen(
                client: client,
                proximity: proximity,
                appearance: appearance,
                onCheckForUpdates: onCheckForUpdates,
                onOpen: { path.append($0) }
            )
        case .relay:
            RelayScreen(client: client, onApplyLan: onApplyLan)
        case .about:
            AboutView(onCheckForUpdates: onCheckForUpdates)
        }
    }

}

// MARK: - Navigation state + titlebar Back button

/// The sub-screen stack, pulled out of `DashboardView`'s `@State` so a view *outside* its tree —
/// the titlebar accessory below — can read and pop it.
@MainActor @Observable
final class DashboardNav {
    var path: [DashRoute] = []
    func pop() { if !path.isEmpty { path.removeLast() } }
}

extension DashRoute {
    var title: String {
        switch self {
        case .clipboard: return "Clipboard History"
        case .settings: return "Settings"
        case .relay: return "Relay Server"
        case .about: return "About"
        }
    }
}

/// "‹ Back  <screen title>", shown only while a sub-screen is open (the home screen leaves it
/// empty). Hosted in a titlebar accessory so it sits beside the traffic lights.
private struct TitlebarBackView: View {
    let nav: DashboardNav

    var body: some View {
        HStack(spacing: 10) {
            if let route = nav.path.last {
                Button(action: nav.pop) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Back").font(M3.labelLarge)
                    }
                    .foregroundStyle(M3.onSurfaceVariant)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(route.title).font(M3.titleMedium).foregroundStyle(M3.onSurface)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

/// A `.leading` titlebar accessory — AppKit places it in the titlebar row next to the traffic
/// lights. Used instead of drawing the button from SwiftUI because the dashboard's titlebar is
/// transparent over full-size content, and SwiftUI content laid out into that band is not shown.
@MainActor
func makeDashboardBackAccessory(nav: DashboardNav) -> NSTitlebarAccessoryViewController {
    let host = NSHostingView(rootView: TitlebarBackView(nav: nav))
    host.sizingOptions = []                      // keep the frame below; don't resize to content
    host.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = host
    accessory.layoutAttribute = .leading
    return accessory
}
