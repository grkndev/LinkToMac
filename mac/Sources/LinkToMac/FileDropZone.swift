import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window's drop surface: while a drag hovers, the content area (not the sidebar or the
/// toolbar) is covered by a dashed, tinted panel with a big arrow — "Drop to send to <phone>".
/// The transfer itself is then shown by the Files page, which a drop switches to.
struct DropOverlay: View {
    let phoneName: String
    /// "3 items" while dragging, when the count is known (nil → the generic line).
    var itemCount: Int? = nil

    var body: some View {
        ZStack {
            M3.surface.opacity(0.72)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(M3.primaryContainer.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(M3.primary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
                .padding(.leading, 22).padding(.trailing, 22).padding(.top, 4).padding(.bottom, 22)
            VStack(spacing: 14) {
                Circle().fill(M3.primary).frame(width: 80, height: 80)
                    .overlay(Image(systemName: "arrow.down").font(.system(size: 34, weight: .medium))
                        .foregroundStyle(M3.onPrimary))
                Text("Drop to send to \(phoneName)")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(M3.onSurface)
                Text("Lands in Downloads on your phone")
                    .font(.system(size: 14)).foregroundStyle(M3.onSurfaceVariant)
            }
        }
    }
}

/// The menu panel's drop state: a tinted zone to drop on and, under it, the batch in flight.
struct PanelDropContent: View {
    let phoneName: String
    let targeted: Bool
    let outgoing: BatchProgress?

    var body: some View {
        VStack(spacing: 12) {
            if targeted || outgoing == nil {
                VStack(spacing: 10) {
                    Circle().fill(M3.primary).frame(width: 52, height: 52)
                        .overlay(Image(systemName: "arrow.down").font(.system(size: 24, weight: .medium))
                            .foregroundStyle(M3.onPrimary))
                    Text("Drop to send to \(phoneName)").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(M3.onSurface).multilineTextAlignment(.center)
                    Text("Opens by itself while you drag").font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity).frame(height: 204)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.primaryContainer.opacity(0.55)))
            }
            if let outgoing {
                VStack(spacing: 8) {
                    HStack {
                        Text("Sending \(outgoing.currentName)").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.detail(outgoing)).font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant).monospacedDigit()
                    }
                    DSProgressBar(fraction: outgoing.overallFraction, height: 4)
                }
            }
        }
    }

    private static func detail(_ b: BatchProgress) -> String {
        let pct = Int((b.overallFraction * 100).rounded())
        return b.count > 1 ? "\(b.index) / \(b.count) · \(pct)%" : "\(pct)%"
    }
}

/// Makes a view a drop target for files headed to the phone. It draws nothing itself — the window
/// and the menu panel each show their own drop state from `isTargeted`.
struct PhoneFileDrop: ViewModifier {
    let client: RelayClient
    @Binding var isTargeted: Bool

    /// File URLs (Finder) plus the pasteboard types of a file *promise* — a Mail attachment, a Photos
    /// item, a Safari download. Those are AppKit pasteboard types, not declared UTIs, hence
    /// `importedAs:`. Without them a promise-only drag is never offered to this view.
    private static let acceptedTypes: [UTType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { UTType(importedAs: $0) }

    func body(content: Content) -> some View {
        content
            .onDrop(of: Self.acceptedTypes, isTargeted: $isTargeted) { providers in
                NSLog("[LinkToMac] drop received: %d provider(s)", providers.count)
                guard !providers.isEmpty else { return false }
                Self.collect(providers) { urls, unreadable in
                    if !urls.isEmpty { client.sendFilesToPhone(urls) }
                    if unreadable > 0 {
                        // Something that is neither a readable file nor a file promise we could
                        // receive (or a promise whose source app didn't deliver). Say so, not nothing.
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
                    group.leave()
                } else if let type = DropStaging.fileLikeType(among: provider.registeredTypeIdentifiers),
                          let folder = box.stagingFolder() {
                    // A file *promise* (Mail, Photos, Safari): ask the source app to write the file,
                    // and keep a copy where the sender can read it for as long as the app runs.
                    provider.loadFileRepresentation(forTypeIdentifier: type) { temp, _ in
                        // `temp` is deleted when this block returns, so the copy has to happen here.
                        if let temp, let staged = try? DropStaging.stage(
                            copying: temp, suggestedName: provider.suggestedName, typeIdentifier: type, into: folder) {
                            box.add(staged)
                        } else {
                            box.addUnreadable()
                        }
                        group.leave()
                    }
                } else {
                    box.addUnreadable()
                    group.leave()
                }
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

    private var folder: URL?

    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func addUnreadable() { lock.lock(); unreadable += 1; lock.unlock() }

    /// One staging folder for the whole drop, made the first time a promise needs it.
    func stagingFolder() -> URL? {
        lock.lock(); defer { lock.unlock() }
        if folder == nil { folder = try? DropStaging.makeFolder() }
        return folder
    }
    func snapshot() -> ([URL], Int) { lock.lock(); defer { lock.unlock() }; return (urls, unreadable) }
}

extension View {
    /// Accept dropped files and send them to the phone; `isTargeted` is true while a drag hovers.
    func phoneFileDrop(client: RelayClient, isTargeted: Binding<Bool>) -> some View {
        modifier(PhoneFileDrop(client: client, isTargeted: isTargeted))
    }
}
