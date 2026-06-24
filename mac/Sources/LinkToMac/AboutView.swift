import SwiftUI
import AppKit

/// The "About" sub-screen pushed from Settings. Redesigned in the M3 dashboard language: an
/// expressive hero (tonal app badge + name + tagline + version chip), a Check-for-Updates row, and
/// a connected LINKS group (changelog, source, developer, contact) with trailing external-link
/// glyphs. Hosted inside the dashboard's route stack.
struct AboutView: View {
    private static let repoURL = "https://github.com/grkndev/LinkToMac"
    private static let profileURL = "https://grkn.dev"
    private static let releasesURL = "https://github.com/grkndev/LinkToMac/releases"
    private static let contactEmail = "info@grkn.dev"

    /// User-initiated Sparkle check, supplied by the AppDelegate that owns the updater.
    let onCheckForUpdates: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                M3SettingsRow(icon: "arrow.triangle.2.circlepath", title: "Check for Updates",
                              subtitle: "Get the latest version", trailingSymbol: nil,
                              position: .single, action: onCheckForUpdates)

                VStack(alignment: .leading, spacing: 8) {
                    M3SectionHeader("LINKS")
                    VStack(spacing: 3) {
                        M3SettingsRow(icon: "doc.text", title: "Release notes",
                                      trailingSymbol: "arrow.up.right", position: .first) { open(Self.releasesURL) }
                        M3SettingsRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source code",
                                      trailingSymbol: "arrow.up.right", position: .middle) { open(Self.repoURL) }
                        M3SettingsRow(icon: "person.crop.circle", title: "Developer", subtitle: "grkndev",
                                      trailingSymbol: "arrow.up.right", position: .middle) { open(Self.profileURL) }
                        M3SettingsRow(icon: "envelope", title: "Contact", subtitle: Self.contactEmail,
                                      trailingSymbol: "arrow.up.right", position: .last) { open("mailto:\(Self.contactEmail)") }
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M3.surface)
    }

    // MARK: - Hero

    private var header: some View {
        VStack(spacing: 14) {
            appIcon
            VStack(spacing: 4) {
                Text("Link to Mac")
                    .font(M3.headline(28))
                    .foregroundStyle(M3.onSurface)
                
                (Text("Android ") +
                 Text(Image(systemName: "arrow.left.arrow.right")).font(.system(size: 12)) +
                 Text(" Mac clipboard & control"))
                    .font(M3.bodyLarge)
                    .foregroundStyle(M3.onSurfaceVariant)
            }
            M3Chip(icon: "checkmark.seal.fill", text: "Version \(version) (\(build))")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The app's real Dock icon (the composed `AppIcon`). Falls back to a tonal badge if the running
    /// app reports no icon image.
    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: M3.corExtraLarge, style: .continuous)
                    .fill(M3.primaryContainer)
                    .overlay(
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(M3.onPrimaryContainer)
                    )
            }
        }
        .frame(width: 100, height: 100)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
