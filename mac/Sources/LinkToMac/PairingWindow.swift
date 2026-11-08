import SwiftUI
import AppKit

/// Lets code that has no reference to the app delegate (the Settings window) bring up the pairing
/// window, the same way `SettingsOpener` does for Settings.
@MainActor
final class PairingOpener {
    static let shared = PairingOpener()
    var open: (() -> Void)?
}

/// "Pair your phone": the first thing a new install shows, and what Settings ▸ Show QR Code… and
/// Unpair bring back. Steps on the left, the QR the phone scans on the right; it closes by itself
/// once the phone connects. Measurements are the design's (760 × 500 window, 44 pt margins).
struct PairingScreen: View {
    let client: RelayClient
    /// "Set up later": dismiss and carry on to the dashboard.
    let onLater: () -> Void

    private static let androidAppURL = URL(string: "https://github.com/grkndev/LinkToMac/releases/latest")!

    /// Six characters of the room id, enough to tell two pairings apart at a glance.
    private var roomTag: String {
        String(client.pairing.room.filter { $0.isLetter || $0.isNumber }.prefix(6)).uppercased()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Pair your phone")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(M3.onSurface)
                    .padding(.top, 20)
                Text("Link to Mac keeps your clipboard, files, notifications and messages in sync with your Android phone. Everything is end-to-end encrypted.")
                    .font(.system(size: 14)).foregroundStyle(M3.onSurfaceVariant)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 15) {
                    step(1, "Open Link to Mac on your phone", "Android 12 or later")
                    step(2, "Tap Scan QR code", "On first launch, or Settings ▸ Re-pair")
                    step(3, "Point the camera at this code", "Pairing finishes on its own")
                }
                .padding(.top, 20)
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    Link(destination: Self.androidAppURL) {
                        Text("Get Link to Mac for Android ↗").font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(M3.primary)
                    }
                    Button(action: onLater) {
                        Text("Set up later").font(.system(size: 12.5)).foregroundStyle(M3.outline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 316, alignment: .leading)
            Spacer(minLength: 36)
            qrCard
        }
        .padding(.horizontal, 44).padding(.top, 48).padding(.bottom, 36)
        .frame(width: 760, height: 500)
        .background(M3.surface)
        // The titlebar is transparent and the content runs under it, as in the dashboard.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(M3.primaryContainer).frame(width: 24, height: 24)
                .overlay(Text("\(number)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(M3.onPrimaryContainer))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(M3.onSurface)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
            }
            .padding(.top, 1)
        }
    }

    private var qrCard: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
                if let image = QRCode.image(from: client.pairingQRPayload, size: 196) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 196, height: 196)
                } else {
                    Text("Couldn't create the code").font(.system(size: 12.5)).foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 224, height: 224)

            Text("ROOM · \(roomTag)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(M3.onSurface)
                .padding(.top, 16)
            HStack(spacing: 7) {
                Circle().fill(client.isLinked ? M3.success : M3.warning).frame(width: 7, height: 7)
                Text(client.isLinked ? "Connected" : "Waiting for your phone…")
                    .font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
            }
            .padding(.top, 8)

            // A Keychain save failure means this pairing only lives for the session — the next
            // launch mints a different room/key and strands the phone. Don't let that be silent.
            if PairingStore.persistFailed {
                Label("The pairing couldn't be saved to the Keychain — it resets when the app restarts.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(M3.warning)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10).padding(.horizontal, 16)
            }
        }
        .frame(width: 320, height: 416)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(M3.surfaceContainer))
    }
}
