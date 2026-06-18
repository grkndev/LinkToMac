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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Relay Server").font(.system(size: 15, weight: .semibold))
                Text("Where this Mac and your phone meet. These values are embedded in the pairing QR, so the phone configures itself on scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeled("Server address", caption: "Domain (for TLS) or IP") {
                TextField("relay.example.com", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
            }

            HStack(alignment: .top, spacing: 14) {
                labeled("Port", caption: portValue == nil ? "1–65535" : " ") {
                    TextField("443", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("TLS").font(.system(size: 12, weight: .medium))
                    Toggle("Use wss://", isOn: $secure)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(secure ? "Encrypted (needs a cert)" : "Plaintext — LAN only")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            labeled("Password", caption: "Must match the server's RELAY_AUTH_TOKEN") {
                SecureField("relay password", text: $token)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("LAN-direct (no relay on the same Wi-Fi)", isOn: $lanEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("This Mac runs a local server the phone connects to directly. The relay above is then only used when you're away.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if lanEnabled {
                    labeled("LAN port", caption: lanPortValue == nil ? "1–65535" : " ") {
                        TextField("53124", text: $lanPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func labeled<C: View>(_ label: String, caption: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            content()
            Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary)
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
