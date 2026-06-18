import SwiftUI
import AppKit

/// Standalone "About" window: app identity + version, plus links to the changelog, source,
/// developer profile, and contact. Mirrors `MenuPanel`'s System-Settings card language via the
/// shared building blocks in `PanelComponents`.
struct AboutView: View {
    private static let repoURL = "https://github.com/grkndev/LinkToMac"
    private static let profileURL = "https://grkn.dev"
    private static let releasesURL = "https://github.com/grkndev/LinkToMac/releases"
    private static let contactEmail = "info@grkn.dev"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("ABOUT")
                Card {
                    InfoRow(icon: "info.circle", title: "Version", value: "\(version) (\(build))")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("LINKS")
                Card {
                    ButtonRow(icon: "doc.text", title: "Release notes…",
                              showsChevron: true, trailingSymbol: "arrow.up.right") {
                        open(Self.releasesURL)
                    }
                    RowDivider()
                    ButtonRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source code…",
                              showsChevron: true, trailingSymbol: "arrow.up.right") {
                        open(Self.repoURL)
                    }
                    RowDivider()
                    ButtonRow(icon: "person.crop.circle", title: "Developer — grkndev",
                              showsChevron: true, trailingSymbol: "arrow.up.right") {
                        open(Self.profileURL)
                    }
                    RowDivider()
                    ButtonRow(icon: "envelope", title: "Contact…",
                              showsChevron: true, trailingSymbol: "arrow.up.right") {
                        open("mailto:\(Self.contactEmail)")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text("LinkToMac").font(.system(size: 16, weight: .semibold))
            Text("Phone ↔ Mac clipboard & control")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
