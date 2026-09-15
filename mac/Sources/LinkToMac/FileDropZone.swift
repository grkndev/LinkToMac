import SwiftUI
import UniformTypeIdentifiers

/// The "drop a file to send it to your phone" surface, shared by the dashboard window and the
/// menu-bar panel so both read identically. Three states: inviting (something is being dragged
/// over us), sending (a live percentage), and nothing at all.
///
/// Deliberately **not** a button: the panel and the window differ in size and chrome, but the drop
/// affordance is the same idea in both, so it is one view parameterised by size.
struct FileDropZone: View {
    let phoneName: String
    /// Non-nil while a transfer is running — takes precedence over the drag invitation.
    let outgoing: TransferProgress?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            if let outgoing {
                sending(outgoing)
            } else {
                invitation
            }
        }
        .frame(maxWidth: .infinity)
        .padding(compact ? 16 : 28)
        .background(
            RoundedRectangle(cornerRadius: compact ? M3.corLargeIncreased : M3.corExtraLarge,
                             style: .continuous)
                .fill(M3.surfaceContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? M3.corLargeIncreased : M3.corExtraLarge,
                             style: .continuous)
                .strokeBorder(M3.primary, style: StrokeStyle(lineWidth: 2, dash: outgoing == nil ? [7, 5] : []))
        )
    }

    private var invitation: some View {
        Group {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: compact ? 26 : 40, weight: .light))
                .foregroundStyle(M3.primary)
            Text("Drop to send to \(phoneName)")
                .font(compact ? M3.bodyLarge : M3.headline(20))
                .foregroundStyle(M3.onSurface)
                .multilineTextAlignment(.center)
            if !compact {
                Text("Lands in Downloads on your phone")
                    .font(M3.bodyLarge)
                    .foregroundStyle(M3.onSurfaceVariant)
            }
        }
    }

    private func sending(_ file: TransferProgress) -> some View {
        Group {
            Text(file.name)
                .font(compact ? M3.bodyLarge : M3.headline(20))
                .foregroundStyle(M3.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            // A determinate bar rather than a spinner: a big file over the relay is paced, so
            // "it's working" is not the question — "how much longer" is.
            ProgressView(value: file.fraction)
                .progressViewStyle(.linear)
                .tint(M3.primary)
            Text("\(file.percent)%")
                .font(M3.bodyLarge)
                .foregroundStyle(M3.onSurfaceVariant)
                .monospacedDigit()
        }
    }
}

/// Makes a whole view a drop target for files headed to the phone: while a drag hovers, the
/// content is replaced by a `FileDropZone` (the user asked for the current screen to *become* the
/// drop target rather than to gain a small well somewhere), and the zone stays up, showing a
/// percentage, for as long as the transfer runs.
struct PhoneFileDrop: ViewModifier {
    let client: RelayClient
    var compact = false

    @State private var targeted = false

    private var showing: Bool { targeted || client.outgoingFile != nil }

    func body(content: Content) -> some View {
        content
            .overlay {
                if showing {
                    ZStack {
                        M3.surface.opacity(0.94)
                        FileDropZone(
                            phoneName: client.phoneName ?? "your phone",
                            outgoing: client.outgoingFile,
                            compact: compact
                        )
                        .padding(compact ? 12 : 48)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showing)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                NSLog("[LinkToMac] drop received: %d provider(s)", providers.count)
                guard let provider = providers.first else { return false }
                // `loadDataRepresentation` rather than `loadObject(ofClass: URL.self)`: the data
                // form is what a file-URL item always carries, and it needs no bridging.
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        NSLog("[LinkToMac] drop had no usable file URL")
                        return
                    }
                    Task { @MainActor in client.sendFileToPhone(url) }
                }
                return true
            }
    }
}

extension View {
    /// Accept dropped files and send them to the phone. `compact` tightens the overlay for the
    /// menu-bar panel.
    func phoneFileDrop(client: RelayClient, compact: Bool = false) -> some View {
        modifier(PhoneFileDrop(client: client, compact: compact))
    }
}
