import SwiftUI
import AppKit

/// The "Server Settings…" window: where the user enters the relay endpoint (host / port / TLS /
/// password) at runtime. Saving persists via `ServerSettingsStore`, then (re)connects the relay
/// so the change takes effect immediately. These values are also embedded in the pairing QR, so
/// the phone configures itself on scan.
struct ServerSettingsView: View {
    let client: RelayClient
    let onSaved: () -> Void

    @State private var host: String
    @State private var port: String
    @State private var secure: Bool
    @State private var token: String
    @State private var lanEnabled: Bool
    @State private var lanPort: String

    init(client: RelayClient, onSaved: @escaping () -> Void) {
        self.client = client
        self.onSaved = onSaved
        let s = ServerSettingsStore.load()
        _host = State(initialValue: s.host)
        _port = State(initialValue: String(s.port))
        _secure = State(initialValue: s.secure)
        _token = State(initialValue: s.token)
        _lanEnabled = State(initialValue: s.lanEnabled)
        _lanPort = State(initialValue: String(s.lanPort))
    }

    private var portValue: Int? {
        guard let p = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }
    private var lanPortValue: Int? {
        guard let p = Int(lanPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }
    private var hasRelay: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSave: Bool {
        // At least one transport must be valid: a relay endpoint, or LAN-direct.
        (hasRelay && portValue != nil) || (lanEnabled && lanPortValue != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                M3SectionHeader("RELAY SERVER")
                Text("Where this Mac and your phone meet. These values ride in the pairing QR, so the phone configures itself on scan.")
                    .font(M3.bodyMedium)
                    .foregroundStyle(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 6)
                VStack(spacing: 3) {
                    M3FieldRow(icon: "network", label: "Server address",
                               placeholder: "relay.example.com — domain (for TLS) or IP",
                               text: $host, position: .first)
                    M3FieldRow(icon: "number", label: "Port", placeholder: "443",
                               invalid: hasRelay && portValue == nil, text: $port, position: .middle)
                    M3ToggleRow(icon: "lock.shield.fill", title: "TLS (wss://)",
                                subtitle: secure ? "Encrypted — needs a certificate" : "Plaintext — LAN only",
                                isOn: $secure, position: .middle)
                    M3FieldRow(icon: "key.fill", label: "Password",
                               placeholder: "matches the server's RELAY_AUTH_TOKEN",
                               secure: true, text: $token, position: .last)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                M3SectionHeader("LAN-DIRECT")
                VStack(spacing: 3) {
                    M3ToggleRow(icon: "wifi", title: "LAN-direct",
                                subtitle: "Phone connects straight to this Mac over Wi-Fi",
                                isOn: $lanEnabled, position: lanEnabled ? .first : .single)
                    if lanEnabled {
                        M3FieldRow(icon: "number", label: "LAN port", placeholder: "53124",
                                   invalid: lanPortValue == nil, text: $lanPort, position: .last)
                    }
                }
            }

            HStack {
                Spacer()
                M3Button(title: "Save", enabled: canSave) { save() }
            }
        }
    }

    private func save() {
        ServerSettingsStore.save(ServerSettings(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue ?? 443,
            secure: secure,
            token: token.trimmingCharacters(in: .whitespaces),
            lanEnabled: lanEnabled,
            lanPort: lanPortValue ?? ServerSettingsStore.defaultLanPort
        ))
        // Apply immediately: reconnect the relay if already active, otherwise start it. `onSaved`
        // also reapplies the LAN server (port/enabled may have changed).
        if client.isActive { client.reconnect() } else { client.connect() }
        onSaved()
    }
}
