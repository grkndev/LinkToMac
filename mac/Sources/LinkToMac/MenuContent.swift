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

        Toggle("Start at Login", isOn: Binding(
            get: { LoginItem.isEnabled },
            set: { try? LoginItem.setEnabled($0) }
        ))

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
