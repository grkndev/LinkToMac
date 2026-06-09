import SwiftUI
import AppKit

struct MenuContent: View {
    let client: RelayClient
    let onShowPairing: () -> Void

    var body: some View {
        Text(client.statusText)
        Text(client.peerText)
        if let clip = client.lastClip {
            Text("Son pano: \(clip.count > 40 ? String(clip.prefix(40)) + "…" : clip)")
                .font(.caption)
        }
        if let error = client.lastError {
            Text(error)
                .font(.caption)
        }

        Divider()

        Button("Pairing QR…") {
            onShowPairing()
        }

        Button(client.isActive ? "Disconnect" : "Connect") {
            client.toggle()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
