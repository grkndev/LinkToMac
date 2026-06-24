import SwiftUI

/// Pushed from the Settings screen's "Relay Server" row. The dedicated home for the relay endpoint
/// config — host / port / TLS / password + the LAN-direct toggle — rendered by `ServerSettingsView`
/// in the M3 dashboard language. Saving (re)connects the relay and reapplies the LAN server.
struct RelayScreen: View {
    let client: RelayClient
    /// Re-applies the LAN-direct server after the relay/LAN settings are saved (port may change).
    let onApplyLan: () -> Void

    var body: some View {
        ScrollView {
            ServerSettingsView(client: client, onSaved: onApplyLan)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M3.surface)
    }
}
