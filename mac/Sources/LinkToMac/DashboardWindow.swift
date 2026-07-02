import SwiftUI

/// Root view of the main dashboard window (hosted by `AppDelegate.showDashboardWindow()`). A
/// two-column layout matching the reference design: `PhonePanel` on the left, `FeaturePanel` on
/// the right. The Clipboard / Settings / About sub-screens (which replaced the three standalone
/// `NSWindow`s) are shown via an **explicit `path` stack with a custom back bar** rather than a
/// `NavigationStack` — a hosted `NSHostingController` window doesn't render the navigation
/// titlebar back button, so we draw our own.
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

    /// Sub-screen stack. Empty == the dashboard home. Push appends, the back bar pops.
    @State private var path: [DashRoute] = []

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
                VStack(spacing: 0) {
                    backBar(title: title(for: route))
                    Divider().overlay(M3.outlineVariant)
                    screen(for: route)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(M3.surface)
                // Let the back bar rise into the titlebar region so it sits level with the traffic
                // lights instead of below the top safe-area inset.
                .ignoresSafeArea(.container, edges: .top)
            }
        }
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

    private func backBar(title: String) -> some View {
        HStack(spacing: 12) {
            Button { if !path.isEmpty { path.removeLast() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    Text("Back").font(M3.labelLarge)
                }
                .foregroundStyle(M3.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.leading, 80)  // start just right of the traffic lights
        .padding(.trailing, 16)
        .frame(height: 30)      // ≈ titlebar height, so content lines up with the traffic lights
        .frame(maxWidth: .infinity)
        .background(M3.surface)
    }

    private func title(for route: DashRoute) -> String {
        switch route {
        case .clipboard: return "Clipboard History"
        case .settings: return "Settings"
        case .relay: return "Relay Server"
        case .about: return "About"
        }
    }
}
