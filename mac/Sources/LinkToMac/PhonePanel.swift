import SwiftUI

/// Left column of the dashboard, styled to match the Jetpack-Compose mobile app's Material 3 look:
/// phone render + identity, tonal status chips, the 2×2 action grid (tall M3 cards with centered
/// circular tonal badges), and the media-player card. Fixed 466 pt wide. **Phase 1: telemetry is
/// hardcoded.** Clipboard / Settings push a sub-screen via `onOpen`; Lock Phone / Cast Screen are
/// visual-only roadmap tiles.
struct PhonePanel: View {
    let client: RelayClient
    let onOpen: (DashRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            Spacer().frame(height: 24)
            actionGrid
            Spacer().frame(height: 16)
            mediaCard
        }
        .frame(width: 466, alignment: .leading)
    }

    // MARK: - Identity

    private var identity: some View {
        HStack(alignment: .center, spacing: 26) {
            Image("PhoneRender")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 118, height: 240)
                

            VStack(alignment: .leading, spacing: 0) {
                Text(client.phoneName ?? "Android")
                    .font(M3.headline(28))
                    .foregroundStyle(M3.onSurface)
                    .lineLimit(1)
                Spacer().frame(height: 10)
                HStack(spacing: 8) {
                    Circle().fill(client.isLinked ? M3.success : M3.onSurfaceVariant)
                        .frame(width: 11, height: 11)
                    Text(client.isLinked ? "Connected" : "Disconnected")
                        .font(M3.bodyLarge).foregroundStyle(M3.onSurfaceVariant)
                }
                Spacer().frame(height: 16)
                statusChips
            }
            Spacer(minLength: 0)
        }
    }

    /// Transport + phone battery. Each chip is hidden until its value is real, so a fresh pairing
    /// simply shows fewer chips. (This Mac's own battery isn't shown — we're already on the Mac.)
    private var statusChips: some View {
        HStack(spacing: 10) {
            M3Chip(icon: transportIcon, text: transportText)
            if let level = client.phoneBatteryLevel {
                M3Chip(icon: Self.batteryIcon(level, charging: client.phoneCharging ?? false),
                       text: "\(level)%")
            }
        }
    }

    private var transportIcon: String {
        if client.lanPeerConnected { return "wifi" }
        if client.peerOnline { return "cloud.fill" }
        return "wifi.slash"
    }
    private var transportText: String {
        if client.lanPeerConnected { return "LAN" }
        if client.peerOnline { return "Relay" }
        return "Offline"
    }

    /// SF Symbol for a battery level (+ charging bolt), matching the system battery glyph steps.
    private static func batteryIcon(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 35..<60: return "battery.50"
        case 10..<35: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: - Actions

    private var actionGrid: some View {
        // Connected 2×2 group: only the block's four outer corners round large, inner corners small.
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                M3ActionTile(icon: "lock.fill", title: "Lock Phone", enabled: false,
                             corners: .grid(row: 0, col: 0, rows: 2, cols: 2))
                M3ActionTile(icon: "airplayvideo", title: "Cast Screen", enabled: false,
                             corners: .grid(row: 0, col: 1, rows: 2, cols: 2))
            }
            GridRow {
                Button { onOpen(.clipboard) } label: {
                    M3ActionTile(icon: "doc.on.doc.fill", title: "Clipboard",
                                 corners: .grid(row: 1, col: 0, rows: 2, cols: 2))
                }
                .buttonStyle(.plain)
                Button { onOpen(.settings) } label: {
                    M3ActionTile(icon: "gearshape.fill", title: "Settings",
                                 corners: .grid(row: 1, col: 1, rows: 2, cols: 2))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Media (roadmap)

    private var mediaCard: some View {
        RoundedRectangle(cornerRadius: M3.corExtraLarge, style: .continuous)
            .fill(M3.surfaceContainer)
            .frame(height: 112)
            .overlay(
                HStack(spacing: 14) {
                    M3IconBadge(icon: "play.fill", size: 44,
                                fill: M3.surfaceContainerHigh, tint: M3.onSurfaceVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Media Player").font(M3.titleMedium).foregroundStyle(M3.onSurfaceVariant)
                        Text("Next Future").font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
            )
    }
}
