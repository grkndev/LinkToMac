import SwiftUI

/// The pairing window contents: the QR the phone scans, plus the room id for reference.
struct PairingView: View {
    let client: RelayClient

    var body: some View {
        VStack(spacing: 16) {
            Text("Eşleştirme")
                .font(.headline)

            if let image = QRCode.image(from: client.pairingQRPayload, size: 240) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                Text("QR oluşturulamadı")
                    .frame(width: 240, height: 240)
            }

            Text("Telefonda Relay sekmesi → “QR Tara” ile bu kodu okut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Room: \(client.pairingRoomShort)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            // A Keychain save failure means this pairing only lives for the session — the next
            // launch mints a different room/key and strands the phone. Don't let that be silent.
            if PairingStore.persistFailed {
                Label("Eşleştirme Anahtarlığa kaydedilemedi — uygulama yeniden başlatılınca sıfırlanır.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
