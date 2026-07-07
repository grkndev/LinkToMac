import AppKit

/// Polls `NSPasteboard.changeCount` (there is no change notification) and reports new text
/// or image copies. Remote clips are written through `write(_:)`, which stamps
/// `lastChangeCount` so the poll never re-broadcasts our own write back to the peer (echo
/// suppression). Images are outbound-only in v1 (no remote image write), so text `write`
/// stamping is the only suppression needed.
@MainActor
final class PasteboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private let onChange: (String) -> Void
    private let onImage: (Data) -> Void

    private static let interval: Duration = .milliseconds(500)

    init(onChange: @escaping (String) -> Void, onImage: @escaping (Data) -> Void) {
        self.onChange = onChange
        self.onImage = onImage
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        // Baseline to "now" so we don't broadcast whatever was already on the clipboard.
        lastChangeCount = pasteboard.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: PasteboardWatcher.interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Write a remote clip to the pasteboard. Both this and `poll()` run on the main
    /// actor, so stamping `lastChangeCount` here is enough to swallow the echo. If the
    /// user copies within the same poll window, last writer wins.
    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    /// Write a remote image (from the phone) to the pasteboard, echo-suppressed like `write(_:)`
    /// so the next poll doesn't bounce it back. JPEG lands under `.tiff` (via `NSImage`) so any
    /// paste target sees a native image; PNG keeps its own type too.
    func writeImage(_ data: Data, mime: String) {
        pasteboard.clearContents()
        if mime == "image/png" {
            pasteboard.setData(data, forType: .png)
        }
        // Also provide a TIFF rendering so apps that only read `.tiff` (most) get the image.
        if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        } else if mime != "image/png" {
            pasteboard.setData(data, forType: .tiff) // last resort: hand over raw bytes
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        // Text wins when both are present (e.g. browser copies put a URL string alongside a
        // TIFF rendering) — matches the pre-image behavior. Image-only copies (screenshots,
        // Preview/Photos "Copy") fall through to the image branch.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onChange(text)
            return
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), !data.isEmpty {
            onImage(data)
        }
    }
}
