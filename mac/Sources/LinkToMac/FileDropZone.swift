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
    /// Non-nil while a batch is running — takes precedence over the drag invitation.
    let outgoing: BatchProgress?
    var compact = false
    /// Cancels the batch in flight; nil hides the button.
    var onCancel: (() -> Void)?

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

    private func sending(_ batch: BatchProgress) -> some View {
        Group {
            // "rapor.pdf (50%)": the file in flight and its own progress…
            Text(batch.label)
                .font(compact ? M3.bodyLarge : M3.headline(20))
                .foregroundStyle(M3.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
            // …under one determinate bar for the whole batch, so it only ever moves forward. A
            // spinner would not do: a big file over the relay is paced, and "how much longer" is
            // the question, not "is it working".
            ProgressView(value: batch.overallFraction)
                .progressViewStyle(.linear)
                .tint(M3.primary)
            HStack(spacing: 12) {
                if batch.count > 1 {
                    Text("\(batch.index) / \(batch.count)")
                        .font(M3.bodyLarge)
                        .foregroundStyle(M3.onSurfaceVariant)
                        .monospacedDigit()
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(M3.bodyLarge)
                        .foregroundStyle(M3.primary)
                }
            }
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

    private var showing: Bool { targeted || client.outgoingBatch != nil }

    func body(content: Content) -> some View {
        content
            .overlay {
                if showing {
                    ZStack {
                        M3.surface.opacity(0.94)
                        FileDropZone(
                            phoneName: client.phoneName ?? "your phone",
                            outgoing: client.outgoingBatch,
                            compact: compact,
                            onCancel: { client.cancelOutgoing() }
                        )
                        .padding(compact ? 12 : 48)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showing)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                NSLog("[LinkToMac] drop received: %d provider(s)", providers.count)
                guard !providers.isEmpty else { return false }
                Self.collect(providers) { urls, unreadable in
                    if !urls.isEmpty { client.sendFilesToPhone(urls) }
                    if unreadable > 0 {
                        // A drag that carries no file URL (a Mail attachment, a Photos item) is a
                        // file *promise*; it can't be read from here. Say so rather than nothing.
                        let what = unreadable == 1 ? "1 item" : "\(unreadable) items"
                        Task { await MacNotifier.post(title: "Couldn't read \(what)", body: "Drop files from Finder instead.") }
                    }
                }
                return true
            }
    }

    /// Resolve every dragged item to a file URL — all of them, not just the first — and hand the
    /// list over once, together, so a multi-file drop is one batch.
    @MainActor
    private static func collect(_ providers: [NSItemProvider],
                                done: @escaping @MainActor ([URL], Int) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers {
            group.enter()
            // `loadDataRepresentation` rather than `loadObject(ofClass: URL.self)`: the data
            // form is what a file-URL item always carries, and it needs no bridging.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    box.add(url)
                } else {
                    box.addUnreadable()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let (urls, unreadable) = box.snapshot()
            MainActor.assumeIsolated { done(urls, unreadable) }
        }
    }
}

/// Collects the results of the item-provider callbacks, which arrive on arbitrary threads.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var unreadable = 0

    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func addUnreadable() { lock.lock(); unreadable += 1; lock.unlock() }
    func snapshot() -> ([URL], Int) { lock.lock(); defer { lock.unlock() }; return (urls, unreadable) }
}

extension View {
    /// Accept dropped files and send them to the phone. `compact` tightens the overlay for the
    /// menu-bar panel.
    func phoneFileDrop(client: RelayClient, compact: Bool = false) -> some View {
        modifier(PhoneFileDrop(client: client, compact: compact))
    }
}
