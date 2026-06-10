import AppKit

/// Polls `NSPasteboard.changeCount` (there is no change notification) and reports new text.
/// Remote clips are written through `write(_:)`, which stamps `lastChangeCount` so the
/// poll never re-broadcasts our own write back to the peer (echo suppression).
@MainActor
final class PasteboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private let onChange: (String) -> Void

    private static let interval: Duration = .milliseconds(500)

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
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

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onChange(text)
    }
}
