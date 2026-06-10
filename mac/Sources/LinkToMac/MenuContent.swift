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

        Button("Unpair…") {
            confirmUnpair()
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

    /// Confirm before discarding the room/key; the phone must rescan a fresh QR after.
    private func confirmUnpair() {
        let alert = NSAlert()
        alert.messageText = "Unpair this Mac?"
        alert.informativeText =
            "The current room and key will be deleted and a new pairing will be generated. "
            + "The phone disconnects and must scan the new QR to pair again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            client.unpair()
        }
    }
}
